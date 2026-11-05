/*
 * Validation: power states (IDLE, SLEEP, DEEP_SLEEP), resume path through the
 * boot ROM, sleep abort, software reset, DVFS, and sleep/wake stress.
 */
#include "test.h"
#include "arch.h"
#include "trap.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"
#include "pm.h"
#ifdef ARCH_RV32M
#include "csr.h"
#endif

#ifndef STRESS_ITERS
#define STRESS_ITERS 24
#endif
/* Wake-up time for SLEEP tests in mtime ticks. It must cover the suspend
 * entry (context save, D$ flush, I$ misses over the CDC bridge), otherwise
 * the power-down is (correctly) aborted. ~250 us at 32 MHz. */
#define SLEEP_TICKS  8000u

volatile uint32_t *suite_scratch(void);
uint32_t ctx_regs_check(pm_ctx_t *ctx);

/* Pre-clean the D$ before arming the wake timer: the flush inside
 * pm_suspend() then only writes back the few lines dirtied since, instead of
 * eating into the sleep time (a wake timer that expires before the WFI makes
 * the PMU refuse the power-down, which pm_suspend reports as PM_ABORTED). */
static int sleep_for(enum pm_state st, uint32_t ticks)
{
    if (st != PM_IDLE) dcache_clean_all();
    pmu_set_wake(PMU_WAKE_MTIP);
    timer_set_cmp(timer_now() + ticks);
    int r = pm_suspend(st, 0);
    timer_cancel();
    return r;
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
    c.magic = 0;
    CHECK(!pm_ctx_valid(&c));               /* invalidated context     */
    return TEST_PASS;
}
TEST(40, "pm_ctx_save_restore", 0, t_ctx_roundtrip);

/* ------------------------------------------------ IDLE */
static int t_idle(void)
{
    uint32_t op = pmu_cur_op();
    uint64_t ratio_x100 = (uint64_t)(REF_HZ >> op) * 100u / AON_HZ;   /* cpu cycles per tick */
    uint32_t idle0 = pmu_read(PMU_CNT_IDLE);
    uint64_t m0 = timer_now();
    uint64_t c0 = arch_cycles();
    timer_set_cmp(m0 + 3000);
    int r = pm_idle();
    uint64_t c1 = arch_cycles();
    uint64_t m1 = timer_now();
    timer_cancel();
    uint64_t running = (m1 - m0) * ratio_x100 / 100u;
    printf_("    %u ticks idle: %u cpu cycles (%u if not gated)\n",
            (unsigned)(m1 - m0), (unsigned)(c1 - c0), (unsigned)running);
    CHECK_EQ(r, PM_WOKE);
    CHECK(m1 >= m0 + 3000);
    CHECK_EQ(pmu_read(PMU_CNT_IDLE), idle0 + 1);
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
    uint32_t cnt0 = pmu_read(deep ? PMU_CNT_DEEP : PMU_CNT_SLEEP);
    uint32_t res0 = h->resumes;
    uint32_t cold0 = h->cold_boots;
#ifdef ARCH_RV32M
    csr_write(mscratch, 0xC0DE1234u);
#endif
    arch_irq_enable(IRQ_MSI);               /* masked source-enable must survive */
    uint64_t cyc0 = arch_cycles();

    int r = sleep_for(st, SLEEP_TICKS);

    uint64_t cyc1 = arch_cycles();
    int msi_en = arch_irq_is_enabled(IRQ_MSI);
    arch_irq_disable(IRQ_MSI);
    printf_("    result %d, off for %u ticks, cycle counter %u -> %u\n", r,
            (unsigned)pmu_read(PMU_OFF_TIME), (unsigned)cyc0, (unsigned)cyc1);
    CHECK_EQ(r, PM_RESUMED);
    CHECK_EQ(pmu_rst_cause(), deep ? PMU_RC_DEEP : PMU_RC_SLEEP);
    CHECK_EQ(h->rst_cause, deep ? PMU_RC_DEEP : PMU_RC_SLEEP);
    CHECK_EQ(h->boot_status, BOOT_RESUMED);
    CHECK_EQ(h->resumes, res0 + 1);
    CHECK_EQ(h->cold_boots, cold0);
    CHECK_EQ(pmu_read(deep ? PMU_CNT_DEEP : PMU_CNT_SLEEP), cnt0 + 1);
    CHECK(pmu_read(PMU_OFF_TIME) > 0);
    CHECK(pmu_read(PMU_WAKE_SRC) & PMU_WAKE_MTIP);
    CHECK(cyc1 < cyc0);                     /* PD_CPU was reset: counter restarted */
    CHECK_EQ(crc32(pat, sizeof(pat)), crc); /* RAM retained */
    CHECK_EQ(cache_ctrl(), CACHE_CTRL_IC_EN | CACHE_CTRL_DC_EN);
    CHECK(msi_en);
    CHECK(!pm_ctx_valid((const pm_ctx_t *)&h->ctx));   /* consumed */
#ifdef ARCH_RV32M
    CHECK_EQ(csr_read(mscratch), 0xC0DE1234u);
#endif
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

static int t_abort(void)
{
    uint32_t sl0 = pmu_read(PMU_CNT_SLEEP), ab0 = pmu_read(PMU_CNT_ABORT);
    uint32_t rc0 = pmu_rst_cause();

    /* 1. wake event already pending: WFI falls through, no power-down */
    pmu_set_wake(PMU_WAKE_MTIP);
    timer_set_cmp(timer_now());
    timer_delay(10);
    int r = pm_suspend(PM_SLEEP, 0);
    timer_cancel();
    CHECK_EQ(r, PM_ABORTED);
    CHECK_EQ(pmu_read(PMU_CNT_SLEEP), sl0);
    CHECK_EQ(pmu_read(PMU_CTRL) & 3u, PMU_MODE_IDLE);

    /* 2. driver refuses a sleep without wake source */
    pmu_set_wake(0);
    CHECK_EQ(pm_suspend(PM_DEEP_SLEEP, 0), PM_EINVAL);

    /* 3. PMU refuses it too (raw request): gate, abort, ungate */
    pmu_write(PMU_EVENT, PMU_EV_SLEEP_ABORT);
    timer_set_cmp(timer_now() + 600);
    pmu_set_mode(PMU_MODE_SLEEP, 0);
    arch_wfi();                              /* ends when the timer fires */
    timer_cancel();
    CHECK_EQ(pmu_read(PMU_CNT_ABORT), ab0 + 1);
    CHECK(pmu_read(PMU_EVENT) & PMU_EV_SLEEP_ABORT);
    CHECK_EQ(pmu_read(PMU_CTRL) & 3u, PMU_MODE_IDLE);
    CHECK_EQ(pmu_read(PMU_CNT_SLEEP), sl0);
    CHECK_EQ(pmu_rst_cause(), rc0);
    pmu_write(PMU_EVENT, PMU_EV_SLEEP_ABORT);
    return TEST_PASS;
}
TEST(44, "pm_sleep_abort", CAP_PMU | CAP_CLINT, t_abort);

/* ------------------------------------------------ reboot tests */
#define SWRST_MARK  0x5357A11Eu
#define NOFL_MARK   0x40F1A5E0u

static int t_swreset(void)
{
    volatile uint32_t *s = suite_scratch();
    s[0] = SWRST_MARK;
    s[1] = HANDOFF->cold_boots;
    pmu_sw_reset();
}

static int t_swreset_after(void)
{
    volatile uint32_t *s = suite_scratch();
    CHECK_EQ(s[0], SWRST_MARK);
    s[0] = 0;
    CHECK_EQ(pmu_rst_cause(), PMU_RC_SWRST);
    CHECK_EQ(HANDOFF->rst_cause, PMU_RC_SWRST);
    CHECK_EQ(HANDOFF->boot_status, BOOT_COLD);
    CHECK_EQ(HANDOFF->cold_boots, s[1] + 1);
    return TEST_PASS;
}
TEST_DEFINE(45, "pm_sw_reset_cold_boot", CAP_PMU | CAP_BOOTROM, t_swreset, t_swreset_after);

static int t_noflush(void)
{
    volatile uint32_t *s = suite_scratch();
    s[0] = NOFL_MARK;
    s[1] = HANDOFF->bad_resumes;
    s[2] = HANDOFF->cold_boots;
    dcache_flush_all();                      /* RAM copy of the context is invalid */
    pmu_set_wake(PMU_WAKE_MTIP);
    timer_set_cmp(timer_now() + SLEEP_TICKS);
    int r = pm_suspend(PM_SLEEP, PM_F_NO_FLUSH);
    timer_cancel();
    printf_("    unexpected return from pm_suspend: %d\n", r);
    return __LINE__;
}

static int t_noflush_after(void)
{
    volatile uint32_t *s = suite_scratch();
    timer_cancel();
    CHECK_EQ(s[0], NOFL_MARK);
    s[0] = 0;
    /* the context never reached RAM: the ROM must refuse it and cold boot */
    CHECK_EQ(pmu_rst_cause(), PMU_RC_SLEEP);
    CHECK_EQ(HANDOFF->boot_status, BOOT_RESUME_BADCTX);
    CHECK_EQ(HANDOFF->bad_resumes, s[1] + 1);
    CHECK_EQ(HANDOFF->cold_boots, s[2] + 1);
    return TEST_PASS;
}
TEST_DEFINE(46, "pm_sleep_without_flush", CAP_PMU | CAP_BOOTROM | CAP_CACHE, t_noflush, t_noflush_after);

/* ------------------------------------------------ DVFS */
static int t_dvfs_switch(void)
{
    static const uint8_t seq[] = {1, 2, 0, 2, 1, 0};
    uint32_t d0 = pmu_read(PMU_CNT_DVFS);
    for (unsigned i = 0; i < ARRAY_SIZE(seq); i++) {
        CHECK_EQ(pm_set_opp(seq[i]), 0);
        uint32_t st = pmu_read(PMU_STATUS);
        CHECK_EQ(PMU_ST_CUR_OP(st), seq[i]);
        CHECK_EQ(PMU_ST_VSEL(st), 2u - seq[i]);
    }
    CHECK_EQ(pmu_read(PMU_CNT_DVFS), d0 + ARRAY_SIZE(seq));
    CHECK_EQ(pm_set_opp(3), PM_EINVAL);
    return TEST_PASS;
}
TEST(50, "dvfs_switch_sequence", CAP_DVFS, t_dvfs_switch);

static int t_dvfs_freq(void)
{
    for (uint32_t op = 0; op < PMU_NUM_OPP; op++) {
        CHECK_EQ(pm_set_opp(op), 0);
        /* warm up the I$ so neither end of the window includes a refill */
        (void)timer_now(); (void)arch_cycles();
        uint64_t m0 = timer_now(), c0 = arch_cycles(), m1;
        while ((m1 = timer_now()) < m0 + 3000) ;
        uint64_t c1 = arch_cycles();
        uint32_t meas = (uint32_t)((c1 - c0) * 1000u / (m1 - m0));
        uint32_t exp  = (uint32_t)((uint64_t)(REF_HZ >> op) * 1000u / AON_HZ);
        printf_("    OP%u: %u.%03u cpu cycles per mtime tick (expected %u.%03u)\n", (unsigned)op,
                (unsigned)(meas / 1000), (unsigned)(meas % 1000), (unsigned)(exp / 1000), (unsigned)(exp % 1000));
        CHECK(meas > exp - exp / 50 && meas < exp + exp / 50);   /* +-2 % */
    }
    CHECK_EQ(pm_set_opp(0), 0);
    return TEST_PASS;
}
TEST(51, "dvfs_frequency_measured", CAP_DVFS | CAP_COUNTERS, t_dvfs_freq);

static int t_dvfs_idle_only(void)
{
    uint32_t op0 = pmu_cur_op(), d0 = pmu_read(PMU_CNT_DVFS);
    pmu_write(PMU_DVFS_OP, op0 == 2 ? 0 : 2);
    pmu_set_mode(PMU_MODE_IDLE, 1);          /* request, but no WFI */
    timer_delay(500);
    CHECK_EQ(pmu_cur_op(), op0);
    CHECK_EQ(pmu_read(PMU_CNT_DVFS), d0);
    pmu_set_mode(PMU_MODE_IDLE, 0);          /* withdraw */
    CHECK_EQ(pm_set_opp(1), 0);              /* proper path works */
    CHECK_EQ(pmu_read(PMU_CNT_DVFS), d0 + 1);
    CHECK_EQ(pm_set_opp(0), 0);
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
    uint32_t c_idle = pmu_read(PMU_CNT_IDLE), c_sleep = pmu_read(PMU_CNT_SLEEP);
    uint32_t c_deep = pmu_read(PMU_CNT_DEEP), c_dvfs = pmu_read(PMU_CNT_DVFS);
    uint32_t res0 = HANDOFF->resumes;

    for (unsigned i = 0; i < 256; i++) sdata[i] = i * 0x01000193u;
    for (unsigned it = 0; it < STRESS_ITERS; it++) {
        uint32_t r = rand_next(&seed);
        enum pm_state st = (enum pm_state)(r % 3);
        /* suspend entry time scales with the CPU clock */
        uint32_t ticks = (st == PM_IDLE ? 400u : SLEEP_TICKS << pmu_cur_op()) + (r >> 4) % 4000u;
        if ((it & 3) == 3) {
            uint32_t op = (r >> 12) % PMU_NUM_OPP;
            CHECK_EQ(pm_set_opp(op), 0);
            n_dvfs++;
        }
        for (unsigned k = 0; k < 16; k++) sdata[rand_next(&seed) & 255] ^= rand_next(&seed);
        uint32_t crc = crc32(sdata, sizeof(sdata));
        int res = sleep_for(st, ticks);
        if (res != (st == PM_IDLE ? PM_WOKE : PM_RESUMED) || crc32(sdata, sizeof(sdata)) != crc) {
            printf_("    iteration %u: %s for %u ticks at OP%u -> result %d\n", it, names[st],
                    (unsigned)ticks, (unsigned)pmu_cur_op(), res);
            CHECK(0);
        }
        if (st != PM_IDLE)
            CHECK_EQ(pmu_rst_cause(), st == PM_SLEEP ? PMU_RC_SLEEP : PMU_RC_DEEP);
        n[st]++;
    }
    CHECK_EQ(pm_set_opp(0), 0);
    n_dvfs++;
    printf_("    %u iterations: idle %u, sleep %u, deep %u, dvfs %u\n", STRESS_ITERS,
            (unsigned)n[0], (unsigned)n[1], (unsigned)n[2], (unsigned)n_dvfs);
    CHECK_EQ(pmu_read(PMU_CNT_IDLE) - c_idle, n[0]);
    CHECK_EQ(pmu_read(PMU_CNT_SLEEP) - c_sleep, n[1]);
    CHECK_EQ(pmu_read(PMU_CNT_DEEP) - c_deep, n[2]);
    CHECK_EQ(pmu_read(PMU_CNT_DVFS) - c_dvfs, n_dvfs);
    CHECK_EQ(HANDOFF->resumes - res0, n[1] + n[2]);
    return TEST_PASS;
}
TEST(60, "stress_sleep_wake_dvfs", CAP_PMU | CAP_DVFS | CAP_BOOTROM | CAP_CLINT, t_stress);
