/*
 * Validation: power states (IDLE, SLEEP, DEEP_SLEEP), the resume path through
 * the boot ROM (doc/BOOT_ABI.md), refused and aborted entries, DVFS, and
 * sleep/wake stress, on the SoC PMU (doc/SOC_REGMAP.md).
 *
 * Every power test passes only if the requested transition completed
 * (doc/SPEC.md): pm_* results other than PM_WOKE (IDLE) / PM_RESUMED
 * (SLEEP, DEEP_SLEEP) fail the test unless the test provokes the abort.
 */
#include "test.h"
#include "arch.h"
#include "trap.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"
#include "pm.h"
#include "csr.h"

#ifndef STRESS_ITERS
#define STRESS_ITERS 24
#endif

/* Wake-up time for SLEEP / DEEP_SLEEP in mtime (clk_aon) ticks per operating
 * point. It must cover the suspend entry (context save and CRC, D$ clean,
 * I$ refills over the CDC bridge), which scales with the CPU clock; a timer
 * that expires before the WFI makes the entry abort, which the tests report
 * as a failure (it is not the transition they request). */
static const uint32_t sleep_ticks[PMU_NUM_OPP] = {12000u, 8000u, 6000u};
#define IDLE_TICKS 1500u

volatile uint32_t *suite_scratch(void);
uint32_t ctx_regs_check(pm_ctx_t *ctx);

/* Pre-clean the D$ before arming the wake timer, so the clean inside
 * pm_suspend() only writes back the few lines dirtied since. Wake source:
 * the machine timer (MTIE). */
static int sleep_for(enum pm_state st, uint32_t ticks)
{
    if (st != PM_IDLE && dcache_clean()) return PM_EWB;
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MTI);
    timer_set_cmp(timer_now() + ticks);
    int r = pm_suspend(st, 0);
    timer_cancel();
    arch_irq_mask_restore(mie);
    return r;
}

static int want(enum pm_state st)
{
    return st == PM_IDLE ? PM_WOKE : PM_RESUMED;
}

/* ------------------------------------------------ context save/restore */
static int t_ctx_roundtrip(void)
{
    static pm_ctx_t c;
    uint32_t r = ctx_regs_check(&c);
    if (r) printf_("    s%u not restored\n", (unsigned)(r - 100));
    CHECK_EQ(r, 0);

    /* sealing / validation used by the boot ROM */
    pm_ctx_seal(&c);
    CHECK(pm_ctx_valid(&c));
    c.regs[5] ^= 0x100;
    CHECK(!pm_ctx_valid(&c));               /* CRC catches corruption  */
    c.regs[5] ^= 0x100;
    CHECK(pm_ctx_valid(&c));
    c.arch[7] ^= 1;
    CHECK(!pm_ctx_valid(&c));               /* the CRC covers arch[] too */
    c.arch[7] ^= 1;
    c.magic = 0;
    CHECK(!pm_ctx_valid(&c));               /* invalidated context     */
    /* CRC-32/IEEE check value (doc/BOOT_ABI.md) */
    CHECK_EQ(crc32("123456789", 9), 0xCBF43926u);
    return TEST_PASS;
}
TEST(40, "pm_ctx_save_restore", 0, t_ctx_roundtrip);

/* ------------------------------------------------ IDLE */
static int t_idle(void)
{
    uint32_t op = pmu_cur_op();
    static const uint32_t per[PMU_NUM_OPP] = {OP0_PERIOD_PS, OP1_PERIOD_PS, OP2_PERIOD_PS};
    uint32_t ic0 = pmu_idle_count();
    uint64_t m0 = timer_now();
    uint64_t c0 = arch_cycles();
    int r = sleep_for(PM_IDLE, 8000);
    uint64_t c1 = arch_cycles();
    uint64_t m1 = timer_now();
    uint64_t running = (m1 - m0) * AON_PERIOD_PS / per[op];
    printf_("    %u ticks idle: %u cpu cycles (%u if not gated)\n",
            (unsigned)(m1 - m0), (unsigned)(c1 - c0), (unsigned)running);
    CHECK_EQ(r, PM_WOKE);
    CHECK(m1 >= m0 + 8000);
    CHECK(pmu_wake_cause() & WAKE_MTIP);
    CHECK_EQ(pmu_idle_count(), ic0 + 1);
    CHECK(c1 - c0 < running / 4);           /* clock was gated */
    return TEST_PASS;
}
TEST(41, "pm_idle_clock_gated", CAP_PMU | CAP_CLINT, t_idle);

/* ------------------------------------------------ SLEEP / DEEP_SLEEP */
static uint32_t pat[256] __attribute__((aligned(16)));

static volatile uint32_t ex_count;
static void exc_skip(trap_frame_t *f) { ex_count = ex_count + 1; f->epc += 4; }

static int sleep_test(enum pm_state st)
{
    const int deep = (st == PM_DEEP_SLEEP);
    uint32_t seed = deep ? 0xDEE95EEDu : 0x51EE9u;
    for (unsigned i = 0; i < 256; i++) pat[i] = rand_next(&seed);
    uint32_t crc = crc32(pat, sizeof(pat));
    volatile handoff_t *h = HANDOFF;
    uint32_t cnt0 = pmu_sleep_count();
    uint32_t res0 = h->resumes;
    uint32_t cold0 = h->cold_boots;
    csr_write(mscratch, 0xC0DE1234u);
    arch_irq_enable(IRQ_MSI);               /* an extra mie enable must survive */
    uint64_t cyc0 = arch_cycles();

    int r = sleep_for(st, sleep_ticks[pmu_cur_op()]);

    uint64_t cyc1 = arch_cycles();
    int msi_en = arch_irq_is_enabled(IRQ_MSI);
    arch_irq_disable(IRQ_MSI);
    printf_("    result %d, wake cause 0x%x, cycle counter %u -> %u\n", r,
            (unsigned)pmu_wake_cause(), (unsigned)cyc0, (unsigned)cyc1);
    CHECK_EQ(r, PM_RESUMED);
    CHECK_EQ(h->rst_cause, deep ? RST_DEEP : RST_SLEEP);
    CHECK_EQ(h->boot_status, BOOT_RESUMED);
    CHECK_EQ(h->boot_reason, REASON_OK);
    CHECK_EQ(h->resumes, res0 + 1);
    CHECK_EQ(h->cold_boots, cold0);
    CHECK_EQ(pmu_sleep_count(), cnt0 + 1);
    CHECK(pmu_wake_cause() & WAKE_MTIP);
    CHECK(!(pmu_status() & (PMU_ST_RESUME | PMU_ST_RESUME_DEEP)));   /* consumed by the ROM */
    CHECK_EQ(pmu_read(PMU_SCRATCH1), 0);
    CHECK_EQ(pmu_read(PMU_CTRL), PMU_CTRL_LP_EN | PMU_MODE_IDLE);    /* mode back to IDLE */
    CHECK(cyc1 < cyc0);                     /* PD_CPU was reset: counter restarted */
    CHECK_EQ(crc32(pat, sizeof(pat)), crc); /* RAM retained */
    CHECK(msi_en);
    CHECK(!pm_ctx_valid((const pm_ctx_t *)CTX_ADDR));   /* consumed */
    CHECK_EQ(csr_read(mscratch), 0xC0DE1234u);
    /* trap vector restored */
    ex_count = 0;
    trap_set_exc_handler(exc_skip);
    __asm__ volatile("ecall" ::: "memory");
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 1);
    return TEST_PASS;
}

static int t_sleep(void)      { return sleep_test(PM_SLEEP); }
static int t_deep_sleep(void) { return sleep_test(PM_DEEP_SLEEP); }
TEST(42, "pm_sleep_resume", CAP_PMU | CAP_BOOTROM | CAP_CLINT, t_sleep);
TEST(43, "pm_deep_sleep_resume", CAP_PMU | CAP_BOOTROM | CAP_CLINT, t_deep_sleep);

/* Entries that must not complete, each reported as such (never as success). */
static int t_abort(void)
{
    uint32_t sl0 = pmu_sleep_count();

    /* 1. wake event already pending and enabled: WFI falls through, the core
     *    never reports core_sleep, no power-down */
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MTI);
    timer_set_cmp(timer_now());
    timer_delay(10);
    int r = pm_suspend(PM_SLEEP, 0);
    timer_cancel();
    arch_irq_mask_restore(mie);
    CHECK_EQ(r, PM_ABORTED);
    CHECK_EQ(pmu_sleep_count(), sl0);
    CHECK_EQ(pmu_read(PMU_CTRL), PMU_CTRL_LP_EN | PMU_MODE_IDLE);
    CHECK_EQ(pmu_read(PMU_SCRATCH1), 0);
    CHECK(!pm_ctx_valid((const pm_ctx_t *)CTX_ADDR));

    /* 2. no wake source enabled in mie: the driver refuses (WFI would never
     *    end) */
    mie = arch_irq_mask_save(0);
    r = pm_suspend(PM_DEEP_SLEEP, 0);
    arch_irq_mask_restore(mie);
    CHECK_EQ(r, PM_EINVAL);
    CHECK_EQ(pmu_sleep_count(), sl0);
    return TEST_PASS;
}
TEST(44, "pm_sleep_abort", CAP_PMU | CAP_CLINT, t_abort);

/* ------------------------------------------------ resume rejected: cold boot */
#define BADCRC_MARK 0xBADC0C0Au

static int t_badcrc(void)
{
    volatile uint32_t *s = suite_scratch();
    s[0] = BADCRC_MARK;
    s[1] = HANDOFF->bad_resumes;
    s[2] = HANDOFF->cold_boots;
    s[3] = pmu_sleep_count();
    if (dcache_clean()) return __LINE__;
    uart_flush();
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MTI);
    timer_set_cmp(timer_now() + sleep_ticks[pmu_cur_op()]);
    int r = pm_suspend(PM_SLEEP, PM_F_BAD_CRC);
    timer_cancel();
    arch_irq_mask_restore(mie);
    printf_("    unexpected return from pm_suspend: %d\n", r);
    return __LINE__;
}

static int t_badcrc_after(void)
{
    volatile uint32_t *s = suite_scratch();
    volatile handoff_t *h = HANDOFF;
    timer_cancel();
    CHECK_EQ(s[0], BADCRC_MARK);
    s[0] = 0;
    /* the CPU was powered off; the ROM rejected the context for its CRC and
     * cold-booted the image (the persistent area was kept) */
    CHECK_EQ(h->rst_cause, RST_SLEEP);
    CHECK_EQ(h->boot_status, BOOT_RESUME_BADCTX);
    CHECK_EQ(h->boot_reason, REASON_CRC);
    CHECK_EQ(h->bad_resumes, s[1] + 1);
    CHECK_EQ(h->cold_boots, s[2] + 1);
    CHECK_EQ(pmu_sleep_count(), s[3] + 1);
    CHECK_EQ(pmu_read(PMU_SCRATCH1), 0);
    CHECK(!(pmu_status() & PMU_ST_RESUME));
    return TEST_PASS;
}
TEST_DEFINE(45, "pm_resume_bad_crc_cold_boot", CAP_PMU | CAP_BOOTROM | CAP_CLINT, t_badcrc, t_badcrc_after);

/* ------------------------------------------------ dirty D-cache: refused */
static uint32_t dirty[64] __attribute__((aligned(16)));

/* The PMU powers PD_CPU down only while cache_clean and idle_ack are both
 * asserted (doc/SPEC.md). Without the clean it refuses: ERR_DIRTY, no
 * power-off, the CPU stays clock gated until the wake event, dirty data intact.
 * (The firmware branch's version of this test expected a power cycle and a
 * ROM CRC rejection; doc/SPEC.md forbids that power-down, audit W17.) */
static int t_dirty(void)
{
    volatile uint32_t *c = dirty;
    volatile uint32_t *u = UNCACHED(dirty);
    uint32_t sl0 = pmu_sleep_count();
    CHECK_EQ(dcache_flush(), 0);
    for (unsigned i = 0; i < 64; i++) u[i] = 0;
    for (unsigned i = 0; i < 64; i++) c[i] = 0xD1270000u + i;
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MTI);
    timer_set_cmp(timer_now() + sleep_ticks[pmu_cur_op()]);
    int r = pm_suspend(PM_SLEEP, PM_F_NO_CLEAN);
    timer_cancel();
    arch_irq_mask_restore(mie);
    CHECK_EQ(r, PM_ABORTED);
    CHECK(pmu_status() & PMU_ST_ERR_DIRTY);
    CHECK_EQ(pmu_sleep_count(), sl0);
    CHECK(pmu_wake_cause() & WAKE_MTIP);    /* woke from the gated state */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0xD1270000u + i);
    CHECK_EQ(u[0], 0);                      /* never written back */
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    CHECK_EQ(dcache_clean(), 0);
    return TEST_PASS;
}
TEST(46, "pm_sleep_dirty_refused", CAP_PMU | CAP_CACHE | CAP_CLINT, t_dirty);

/* SLEEP and DEEP_SLEEP woken by the AON wake timer through the interrupt
 * controller (MEIP). */
static int t_sleep_wtimer(void)
{
    for (int deep = 0; deep < 2; deep++) {
        uint32_t cnt0 = pmu_sleep_count();
        CHECK_EQ(dcache_clean(), 0);
        uint32_t mie = arch_irq_mask_save(1u << IRQ_MEI);
        intc_set_enabled(IRQ_WTIMER);
        wtimer_start(sleep_ticks[pmu_cur_op()], 0);
        int r = pm_suspend(deep ? PM_DEEP_SLEEP : PM_SLEEP, 0);
        uint32_t wc = pmu_wake_cause();
        wtimer_stop();
        intc_set_enabled(0);
        arch_irq_mask_restore(mie);
        CHECK_EQ(r, PM_RESUMED);
        CHECK_EQ(HANDOFF->rst_cause, deep ? RST_DEEP : RST_SLEEP);
        CHECK_EQ(pmu_sleep_count(), cnt0 + 1);
        CHECK(wc & WAKE_MEIP);
    }
    return TEST_PASS;
}
TEST(47, "pm_sleep_wake_timer", CAP_PMU | CAP_BOOTROM | CAP_WTIMER | CAP_INTC, t_sleep_wtimer);

/* ------------------------------------------------ DVFS */
static int t_dvfs_switch(void)
{
    /* from OP2 (reset): 2->1 1->2 2->0 0->2 2->1 1->0 0->1: all six pairs */
    static const uint8_t seq[] = {1, 2, 0, 2, 1, 0, 1};
    CHECK_EQ(pmu_cur_op(), PMU_RESET_OP);
    for (unsigned i = 0; i < ARRAY_SIZE(seq); i++) {
        CHECK_EQ(pm_set_opp(seq[i]), 0);
        uint32_t st = pmu_status();
        CHECK_EQ(PMU_ST_CUR_OP(st), seq[i]);
        CHECK(!(st & PMU_ST_DVFS_PEND));
        CHECK_EQ(pmu_read(PMU_VSEL), seq[i]);
        CHECK_EQ(pmu_read(PMU_DVFS), seq[i]);
    }
    /* the current operating point: nothing to do, completes at once */
    CHECK_EQ(pm_set_opp(1), 0);
    CHECK_EQ(pm_set_opp(3), PM_EINVAL);
    CHECK_EQ(pm_set_opp(PMU_RESET_OP), 0);
    return TEST_PASS;
}
TEST(50, "dvfs_switch_sequence", CAP_DVFS, t_dvfs_switch);

static int t_dvfs_freq(void)
{
    static const uint32_t per[PMU_NUM_OPP] = {OP0_PERIOD_PS, OP1_PERIOD_PS, OP2_PERIOD_PS};
    uint32_t meas_prev = 0;
    for (uint32_t op = 0; op < PMU_NUM_OPP; op++) {
        CHECK_EQ(pm_set_opp(op), 0);
        /* warm up the I$ so neither end of the window includes a refill */
        (void)timer_now(); (void)arch_cycles();
        uint64_t m0 = timer_now(), c0 = arch_cycles(), m1;
        while ((m1 = timer_now()) < m0 + 3000) ;
        uint64_t c1 = arch_cycles();
        uint32_t meas = (uint32_t)((c1 - c0) * 1000u / (m1 - m0));
        uint32_t exp  = (uint32_t)((uint64_t)AON_PERIOD_PS * 1000u / per[op]);
        printf_("    OP%u: %u.%03u cpu cycles per mtime tick (expected %u.%03u)\n", (unsigned)op,
                (unsigned)(meas / 1000), (unsigned)(meas % 1000), (unsigned)(exp / 1000), (unsigned)(exp % 1000));
        CHECK(meas > exp - exp / 50 && meas < exp + exp / 50);   /* +-2 % */
        CHECK(meas > meas_prev);                                 /* OP0 slowest */
        meas_prev = meas;
    }
    CHECK_EQ(pm_set_opp(PMU_RESET_OP), 0);
    return TEST_PASS;
}
TEST(51, "dvfs_frequency_measured", CAP_DVFS | CAP_COUNTERS, t_dvfs_freq);

static int t_dvfs_idle_only(void)
{
    uint32_t op0 = pmu_cur_op();
    uint32_t to = op0 == 0 ? 2 : 0;
    pmu_write(PMU_DVFS, to);                 /* request, but no WFI */
    timer_delay(500);
    uint32_t st = pmu_status();
    CHECK_EQ(PMU_ST_CUR_OP(st), op0);
    CHECK(st & PMU_ST_DVFS_PEND);
    CHECK(!(st & PMU_ST_DVFS_DONE));
    CHECK_EQ(pmu_read(PMU_VSEL), op0);
    CHECK_EQ(pm_set_opp(to), 0);             /* applied in IDLE */
    CHECK(!(pmu_status() & PMU_ST_DVFS_PEND));
    CHECK_EQ(pm_set_opp(PMU_RESET_OP), 0);
    return TEST_PASS;
}
TEST(52, "dvfs_only_while_idle", CAP_DVFS, t_dvfs_idle_only);

/* ------------------------------------------------ stress */
static uint32_t sdata[256] __attribute__((aligned(16)));

static int t_stress(void)
{
    static const char *names[] = {"IDLE", "SLEEP", "DEEP"};
    uint32_t seed = 0x5EED1234u;
    uint32_t n[3] = {0, 0, 0}, n_dvfs = 0;
    uint32_t c_sleep = pmu_sleep_count();
    uint32_t res0 = HANDOFF->resumes;

    for (unsigned i = 0; i < 256; i++) sdata[i] = i * 0x01000193u;
    for (unsigned it = 0; it < STRESS_ITERS; it++) {
        uint32_t r = rand_next(&seed);
        enum pm_state st = (enum pm_state)(r % 3);
        if ((it & 3) == 3) {
            uint32_t op = (r >> 12) % PMU_NUM_OPP;
            CHECK_EQ(pm_set_opp(op), 0);
            n_dvfs++;
        }
        /* suspend entry time scales with the CPU clock */
        uint32_t ticks = (st == PM_IDLE ? IDLE_TICKS : sleep_ticks[pmu_cur_op()]) + (r >> 4) % 2000u;
        for (unsigned k = 0; k < 16; k++) sdata[rand_next(&seed) & 255] ^= rand_next(&seed);
        uint32_t crc = crc32(sdata, sizeof(sdata));
        int res = sleep_for(st, ticks);
        if (res != want(st) || crc32(sdata, sizeof(sdata)) != crc) {
            printf_("    iteration %u: %s for %u ticks at OP%u -> result %d\n", it, names[st],
                    (unsigned)ticks, (unsigned)pmu_cur_op(), res);
            CHECK(0);
        }
        if (st != PM_IDLE)
            CHECK_EQ(HANDOFF->rst_cause, st == PM_SLEEP ? RST_SLEEP : RST_DEEP);
        n[st]++;
    }
    CHECK_EQ(pm_set_opp(PMU_RESET_OP), 0);
    printf_("    %u iterations: idle %u, sleep %u, deep %u, dvfs %u\n", STRESS_ITERS,
            (unsigned)n[0], (unsigned)n[1], (unsigned)n[2], (unsigned)n_dvfs);
    CHECK_EQ(pmu_sleep_count() - c_sleep, n[1] + n[2]);
    CHECK_EQ(HANDOFF->resumes - res0, n[1] + n[2]);
    return TEST_PASS;
}
TEST(60, "stress_sleep_wake_dvfs", CAP_PMU | CAP_DVFS | CAP_BOOTROM | CAP_CLINT, t_stress);

/* Deterministic coverage of every power state at every operating point and
 * of every OPP -> OPP transition. Prints the coverage matrix. */
static int t_coverage(void)
{
    static const char *names[] = {"IDLE ", "SLEEP", "DEEP "};
    uint8_t cov[3][PMU_NUM_OPP] = {{0}};
    uint8_t dv[PMU_NUM_OPP][PMU_NUM_OPP] = {{0}};

    for (uint32_t from = 0; from < PMU_NUM_OPP; from++)
        for (uint32_t to = 0; to < PMU_NUM_OPP; to++) {
            if (from == to) continue;
            if (pmu_cur_op() != from) CHECK_EQ(pm_set_opp(from), 0);
            CHECK_EQ(pm_set_opp(to), 0);
            CHECK_EQ(pmu_cur_op(), to);
            dv[from][to] = 1;
        }
    for (uint32_t op = 0; op < PMU_NUM_OPP; op++) {
        if (pmu_cur_op() != op) CHECK_EQ(pm_set_opp(op), 0);
        for (int st = PM_IDLE; st <= PM_DEEP_SLEEP; st++) {
            uint32_t ticks = st == PM_IDLE ? IDLE_TICKS : sleep_ticks[op];
            int r = sleep_for((enum pm_state)st, ticks);
            CHECK_EQ(r, want((enum pm_state)st));
            CHECK_EQ(pmu_cur_op(), op);           /* OPP survives power-down */
            if (st != PM_IDLE)
                CHECK_EQ(HANDOFF->rst_cause, st == PM_SLEEP ? RST_SLEEP : RST_DEEP);
            cov[st][op] = 1;
        }
    }
    CHECK_EQ(pm_set_opp(PMU_RESET_OP), 0);

    puts_("    state x OPP   OP0 OP1 OP2      DVFS from\\to  OP0 OP1 OP2\n");
    for (int st = 0; st < 3; st++) {
        printf_("    %s        ", names[st]);
        for (int op = 0; op < PMU_NUM_OPP; op++) printf_(" %s ", cov[st][op] ? " x" : " -");
        printf_("     OP%d          ", st);
        for (int op = 0; op < PMU_NUM_OPP; op++) printf_(" %s ", st == op ? " ." : dv[st][op] ? " x" : " -");
        putch('\n');
    }
    for (int st = 0; st < 3; st++)
        for (int op = 0; op < PMU_NUM_OPP; op++) {
            CHECK(cov[st][op]);
            CHECK(st == op || dv[st][op]);
        }
    return TEST_PASS;
}
TEST(61, "pm_state_opp_coverage", CAP_PMU | CAP_DVFS | CAP_BOOTROM | CAP_CLINT, t_coverage);

/* ------------------------------------------------ PMU wake mask */
/* A pending interrupt that firmware did not enable in mie must not wake the
 * PMU (stage-1 open item 3). Here MTIP is pending but only MEIE is enabled;
 * the wake timer (intc -> MEIP) ends the wait. Without a wake mask the PMU
 * woke on MTIP, found the core still in WFI and entered IDLE again,
 * repeatedly: the clock ran for most of the wait. */
static int t_wake_mask(void)
{
    uint32_t op = pmu_cur_op();
    static const uint32_t per[PMU_NUM_OPP] = {OP0_PERIOD_PS, OP1_PERIOD_PS, OP2_PERIOD_PS};
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MEI);
    intc_set_enabled(IRQ_WTIMER);
    timer_set_cmp(timer_now());              /* MTIP pending, MTIE off */
    timer_delay(4);
    CHECK(csr_read(mip) & MIP_MTIP);
    uint32_t ic0 = pmu_idle_count();
    uint64_t m0 = timer_now(), c0 = arch_cycles();
    wtimer_start(8000, 0);
    int r = pm_idle();
    uint64_t c1 = arch_cycles(), m1 = timer_now();
    uint32_t wc = pmu_wake_cause();
    uint32_t mask = pmu_wake_mask();
    uint32_t ic1 = pmu_idle_count();
    wtimer_stop();
    intc_set_enabled(0);
    timer_cancel();
    arch_irq_mask_restore(mie);
    uint64_t running = (m1 - m0) * AON_PERIOD_PS / per[op];
    printf_("    %u ticks in WFI with MTIP pending (masked): %u cpu cycles (%u if not gated), %u IDLE entries\n",
            (unsigned)(m1 - m0), (unsigned)(c1 - c0), (unsigned)running, (unsigned)(ic1 - ic0));
    CHECK_EQ(r, PM_WOKE);
    CHECK_EQ(mask, WAKE_MEIP);               /* pm_wfi programmed it from mie */
    CHECK_EQ(ic1 - ic0, 1);                  /* no repeated wake / IDLE cycle */
    CHECK(m1 - m0 >= 8000);
    CHECK(wc & WAKE_MEIP);
    CHECK(c1 - c0 < running / 4);            /* clock stayed gated */
    return TEST_PASS;
}
TEST(48, "pm_wake_mask", CAP_PMU | CAP_CLINT | CAP_WTIMER | CAP_INTC, t_wake_mask);
