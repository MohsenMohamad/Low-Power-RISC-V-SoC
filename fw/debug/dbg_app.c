/*
 * Debug application (doc/DEBUG_SPEC.md section 9): seeded random stress test,
 * debug-driver and wiring test, expected-crash and hang (watchdog) tests,
 * Spike divergence kernel, and the monitor commands dbg / dbgrun next to the
 * shared sleep / opp / exit commands (fw/app/app_cmds.c).
 *
 * Built from the one firmware tree (fw/Makefile app "dbgapp"): the common
 * startup (app/crt0.S), drivers (incl. drivers/dbg.c), pm layer, platform
 * and monitor. Run control, first match wins:
 *   1. host boot argument (doc/BOOT_ABI.md) with bit 31 set: run test
 *      BOOTARG_TEST(arg) with seed / iterations / flags from the host
 *      arguments 0..2, print PASS / FAIL and stop (simulation)
 *   2. debug mailbox (dbg_mbox.h) with state REQUEST, written by the bench:
 *      run that test, print "DBGRUN RESULT: PASS|FAIL", then the monitor
 *   3. otherwise the UART monitor
 * After a watchdog reset (boot ROM rst_cause WDT) the error log is dumped
 * post mortem; the hang test passes only on that path.
 */
#include "app_cmds.h"
#include "arch.h"
#include "dbg_crash.h"
#include "dbg_mbox.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"
#include "pm.h"
#include "trap.h"

static int      sim_mode;              /* host autorun: exit with the verdict */
static uint32_t rng;
static int      quiet;
static int      neg_abort;             /* DBG_F_NEG_ABORT: provoke aborted transitions */

static uint32_t rnd(void)            { return rand_next(&rng); }
static uint32_t rnd_n(uint32_t n)    { return rnd() % n; }

static void finish(uint32_t code)
{
    if (sim_mode) platform_exit(code);
}

/* ================= debug hardware setup ================= */
static void dbg_setup_capture(void)
{
    dbg_trace_cfg_t c = {
        .start_sel = TRC_TRIG_NONE, .stop_sel = TRC_TRIG_NONE,
        .start_pc = 0, .stop_pc = 0, .pc_mask = 0xFFFFFFFFu,
        .ctrl_flags = TRC_CTRL_LOG_TRAP | TRC_CTRL_LOG_PWR | TRC_CTRL_FRZ_EXC | TRC_CTRL_FRZ_ERR,
    };
    dbg_trace_setup(&c);
    dbg_evcnt_ctrl(0, 1);
    if (dbg_evcnt_clear()) puts_("DBG event counter clear did not complete\n");
}

/* ================= random stress test ================= */
#define BUF_WORDS 2048u
static uint32_t buf[BUF_WORDS] __attribute__((aligned(64)));
static uint32_t golden;                 /* CRC of buf after the last change */
static volatile uint32_t irq_cnt;

enum { OP_COMPUTE, OP_MEM, OP_FLUSH, OP_IRQ, OP_SLEEP, OP_DVFS, OP_INJECT, N_OPS };
static const char *const op_name[N_OPS] = {"compute", "mem", "flush", "irq", "sleep", "dvfs", "inject"};
static const uint8_t op_weight[N_OPS - 1] = {6, 5, 3, 3, 3, 2};
static uint32_t op_hits[N_OPS];
static uint32_t cov_ps_op[3][3];        /* power state x operating point */

static void timer_irq(trap_frame_t *f)
{
    (void)f;
    irq_cnt++;
    timer_cancel();
}

static int fail(const char *what, uint32_t a, uint32_t b)
{
    printf_("STRESS CHECK FAILED: %s (0x%08x != 0x%08x) seed=0x%08x\n", what, (unsigned)a, (unsigned)b,
            (unsigned)dbg_crash_seed);
    dbg_errlog_sw_error(0x57000000u | (a & 0xFFFFu));
    dbg_crash_dump("software", 0);
    return -1;
}

static uint32_t kernel(uint32_t x, int variant)
{
    uint32_t acc = 0;
    for (uint32_t i = 0; i < 48; i++) {
        x = x * 1103515245u + 12345u;
        uint32_t d = (x >> 7) | 1u;
        if (variant) acc += (x / d) * 3u + (x % 13u);       /* mul / div / rem */
        else         acc += 3u * (x / d) + (x - (x / 13u) * 13u);
        acc = (acc << 5) | (acc >> 27);
    }
    return acc;
}

static int op_compute(uint32_t arg)
{
    uint32_t a = kernel(arg, 0), b = kernel(arg, 1);
    if (a != b) return fail("compute kernels differ", a, b);
    uint32_t p = (arg & 0xFFFFu) * ((arg >> 16) | 1u);
    if (p / ((arg >> 16) | 1u) != (arg & 0xFFFFu)) return fail("mul/div identity", p, arg);
    return 0;
}

static int op_mem(uint32_t arg)
{
    uint32_t off = arg % (BUF_WORDS - 64u), len = 16u + (arg >> 12) % 48u, st = arg | 1u;
    for (uint32_t i = 0; i < len; i++) buf[off + i] = rand_next(&st);
    st = arg | 1u;
    for (uint32_t i = 0; i < len; i++) {
        uint32_t e = rand_next(&st);
        if (buf[off + i] != e) return fail("mem readback", buf[off + i], e);
    }
    /* clean and compare through the uncached alias */
    if (dcache_clean()) return fail("D-cache clean reported a write-back error", 1, 0);
    volatile uint32_t *u = UNCACHED(&buf[off]);
    for (uint32_t i = 0; i < len; i++)
        if (u[i] != buf[off + i]) return fail("uncached view after clean", u[i], buf[off + i]);
    golden = crc32(buf, sizeof(buf));
    return 0;
}

static int op_flush(uint32_t arg)
{
    int r = 0;
    switch (arg % 3u) {
    case 0: r = dcache_clean(); break;
    case 1: r = dcache_flush(); break;
    default: icache_invalidate(); break;
    }
    if (r) return fail("cache maintenance reported a write-back error", (uint32_t)r, 0);
    uint32_t c = crc32(buf, sizeof(buf));
    if (c != golden) return fail("buffer CRC after cache maintenance", c, golden);
    return 0;
}

static int op_irq(uint32_t arg)
{
    uint32_t before = irq_cnt;
    timer_set_cmp(timer_now() + 40u + arg % 400u);
    for (uint32_t spin = 0; irq_cnt == before && spin < 2000000u; spin++) { }
    timer_cancel();
    if (irq_cnt != before + 1u) return fail("timer interrupt count", irq_cnt, before + 1u);
    return 0;
}

/* A sleep counts (and is recorded as coverage) only if the requested
 * transition completed: PM_WOKE for IDLE (IDLE_CNT advanced), PM_RESUMED for
 * SLEEP / DEEP_SLEEP (powered off and resumed). PM_ABORTED, PM_EWB or any
 * other result is a failure (doc/SPEC.md: an aborted transition is never a
 * pass or coverage). */
static int op_sleep(uint32_t arg)
{
    static const enum pm_state sts[3] = {PM_IDLE, PM_SLEEP, PM_DEEP_SLEEP};
    uint32_t si = arg % 3u;
    uint32_t ticks = 6000u + (arg >> 8) % 6000u;
    if (!(platform_caps() & CAP_PMU)) return 0;
    uint32_t op = pmu_cur_op() % 3u;
    uint32_t sleeps0 = pmu_sleep_count(), idles0 = pmu_idle_count();
    uart_flush();
    /* wake source: the machine timer (MTIE is enabled in mie; pm_suspend
     * writes WAKE_MASK from mie) */
    /* negative test: the timer is already expired at the WFI; interrupts are
     * masked globally so the handler does not consume it first (WFI still
     * ends on it: it is pending and enabled in mie) */
    uint32_t irqs = neg_abort ? arch_irq_save() : 0;
    timer_set_cmp(neg_abort ? timer_now() : timer_now() + ticks);
    int r = pm_suspend(sts[si], 0);
    timer_cancel();
    if (neg_abort) arch_irq_restore(irqs);
    int want = (si == 0) ? PM_WOKE : PM_RESUMED;
    if (r != want) return fail(r == PM_ABORTED ? "sleep transition ABORTED" : "pm_suspend result", (uint32_t)r,
                               (uint32_t)want);
    /* the PMU's own counters confirm the transition */
    if (si == 0 && pmu_idle_count() != idles0 + 1u) return fail("IDLE_CNT after IDLE", pmu_idle_count(), idles0 + 1u);
    if (si != 0 && pmu_sleep_count() != sleeps0 + 1u)
        return fail("SLEEP_CNT after power-down", pmu_sleep_count(), sleeps0 + 1u);
    cov_ps_op[si][op]++;
    uint32_t c = crc32(buf, sizeof(buf));
    if (c != golden) return fail("RAM CRC after wake", c, golden);
    if (!quiet) printf_("  woke result=%d\n", r);
    return 0;
}

static int op_dvfs(uint32_t arg)
{
    uint32_t op = arg % 3u;
    if (!(platform_caps() & CAP_DVFS)) return 0;
    int r = pm_set_opp(op);
    if (r) return fail("pm_set_opp", (uint32_t)r, 0);
    if (pmu_cur_op() != op) return fail("operating point", pmu_cur_op(), op);
    return 0;
}

static void inject(uint32_t kind)
{
    printf_("INJECT kind=%u\n", (unsigned)kind);
    uart_flush();
    switch (kind) {
    case 0: __asm__ volatile(".word 0x00000000"); break;          /* illegal */
    case 1: {                                                     /* misaligned lw */
        uint32_t v, a = (uint32_t)(uintptr_t)buf + 2u;
        __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(a) : "memory");
        (void)v;
        break;
    }
    case 2:                                                       /* load access fault */
        if (arch_caps() & CAP_ACCFAULT) { (void)*(volatile uint32_t *)0x60000000u; break; }
        __asm__ volatile(".word 0x00000000"); break;
    default:                                                      /* hang */
        arch_irq_save();
        for (;;) __asm__ volatile("nop");
    }
}

static int stress(uint32_t iters, uint32_t flags)
{
    uint32_t total_w = 0;
    for (unsigned i = 0; i < N_OPS - 1; i++) total_w += op_weight[i];
    printf_("STRESS seed=0x%08x iters=%u flags=0x%x\n", (unsigned)dbg_crash_seed, (unsigned)iters,
            (unsigned)flags);
    rng = dbg_crash_seed ? dbg_crash_seed : 1u;
    for (unsigned i = 0; i < BUF_WORDS; i++) buf[i] = i * 0x9E3779B9u;
    golden = crc32(buf, sizeof(buf));
    trap_set_irq_handler(IRQ_MTI, timer_irq);
    arch_irq_enable(IRQ_MTI);
    arch_irq_global_enable();
    dbg_wdt_start(4000000u, 0, WDT_CTRL_RST_EN | WDT_CTRL_PAUSE_LP);

    for (uint32_t it = 0; it < iters; it++) {
        uint32_t pick = rnd_n(total_w), op = 0;
        while (pick >= op_weight[op]) pick -= op_weight[op++];
        uint32_t arg = rnd();
        if ((flags & DBG_F_INJECT) && rnd_n(16) == 0) { op = OP_INJECT; arg = rnd_n(4); }
        if (!quiet) printf_("I %u op=%s arg=0x%08x\n", (unsigned)it, op_name[op], (unsigned)arg);
        op_hits[op]++;
        int r = 0;
        switch (op) {
        case OP_COMPUTE: r = op_compute(arg); break;
        case OP_MEM:     r = op_mem(arg); break;
        case OP_FLUSH:   r = op_flush(arg); break;
        case OP_IRQ:     r = op_irq(arg); break;
        case OP_SLEEP:   r = op_sleep(arg); break;
        case OP_DVFS:    r = op_dvfs(arg); break;
        default:         inject(arg); break;
        }
        if (r) { dbg_wdt_stop(); return -1; }
        dbg_wdt_kick();
    }
    dbg_wdt_stop();
    arch_irq_disable(IRQ_MTI);
    for (unsigned i = 0; i < N_OPS; i++) printf_("COV op=%s n=%u\n", op_name[i], (unsigned)op_hits[i]);
    for (unsigned s = 0; s < 3; s++)
        for (unsigned o = 0; o < 3; o++)
            printf_("COV sleep_state=%u opp=%u n=%u\n", s, o, (unsigned)cov_ps_op[s][o]);
    printf_("STRESS PASS seed=0x%08x iters=%u\n", (unsigned)dbg_crash_seed, (unsigned)iters);
    return 0;
}

/* ================= driver and wiring test ================= */
static int t_fail;
static void t_check(int ok, const char *what)
{
    printf_("[DBGT] %-52s %s\n", what, ok ? "PASS" : "FAIL");
    if (!ok) t_fail++;
}

static __attribute__((noinline)) uint32_t marker_a(uint32_t x) { return x * 3u + 1u; }
static __attribute__((noinline)) uint32_t marker_b(uint32_t x) { return x ^ 0x5Au; }
static volatile int exc_seen;
static volatile uint32_t exc_cause_seen, exc_pc_seen;
static void t_exc(trap_frame_t *f) { exc_seen++; exc_cause_seen = f->cause; exc_pc_seen = f->epc; f->epc += 4; }
static volatile int msi_seen, mei_seen;
static void t_msi(trap_frame_t *f) { (void)f; msi_seen++; timer_set_msip(0); }
static volatile uint32_t mei_src;
static void t_mei(trap_frame_t *f)
{
    (void)f;
    mei_seen++;
    mei_src = intc_active();
    intc_set_enabled(0);                    /* the test clears the source */
}

/* Retired instructions recorded by the trace are the instructions in memory
 * (CPU retire port, audit W21). */
static int trace_matches_memory(uint32_t n)
{
    for (uint32_t k = 0; k < n; k++) {
        dbg_trace_entry_t e;
        dbg_trace_get(k, &e);
        if (TRC_INFO_TYPE(e.info) != TRC_TYPE_RETIRE) continue;
        if (e.data != *(volatile uint32_t *)(uintptr_t)e.pc) return 0;
    }
    return 1;
}

/* D-cache hit / miss counters (cache event port, audit B15): 32 loads to
 * distinct lines of a flushed cache are 32 misses, the same loads again 32
 * hits. The loop makes no other cacheable data access. */
#define DLINES 32u
static uint32_t dbuf[DLINES * 4] __attribute__((aligned(16)));
static int dcache_counts_exact(void)
{
    if (dcache_flush()) return 0;
    uint32_t h0 = dbg_evcnt_get(EVC_DC_HIT), m0 = dbg_evcnt_get(EVC_DC_MISS);
    uint32_t sum = 0;
    for (uint32_t pass = 0; pass < 2; pass++)
        for (uint32_t i = 0; i < DLINES; i++)
            sum += ((volatile uint32_t *)dbuf)[i * 4];
    dbg_evcnt_settle();
    uint32_t h1 = dbg_evcnt_get(EVC_DC_HIT), m1 = dbg_evcnt_get(EVC_DC_MISS);
    printf_("    D-cache: %u misses, %u hits (expected %u, %u)\n", (unsigned)(m1 - m0), (unsigned)(h1 - h0),
            DLINES, DLINES);
    (void)sum;
    return m1 - m0 == DLINES && h1 - h0 == DLINES;
}

static int drv_test(void)
{
    dbg_trace_entry_t e;
    dbg_evcnt_t a, b;
    dbg_errlog_t el;
    t_check(dbg_present(), "all four blocks present (ID)");

    /* ---- trace start / stop on PC match, retire port ---- */
    dbg_trace_cfg_t c = {TRC_TRIG_PC, TRC_TRIG_PC, (uint32_t)(uintptr_t)marker_a,
                         (uint32_t)(uintptr_t)marker_b, 0xFFFFFFFFu, TRC_CTRL_LOG_TRAP};
    dbg_trace_setup(&c);
    volatile uint32_t v = marker_a(5);
    v += 7;
    v = marker_b(v);
    for (volatile int i = 0; i < 50; i++) { }
    uint32_t n = dbg_trace_count();
    dbg_trace_get(0, &e);
    t_check(n > 2 && e.pc == (uint32_t)(uintptr_t)marker_a, "trace starts on PC match");
    dbg_trace_get(n - 1, &e);
    t_check((dbg_trace_status() & TRC_ST_STOPPED) && e.pc == (uint32_t)(uintptr_t)marker_b,
            "trace stops on PC match (last entry)");
    t_check(TRC_INFO_TYPE(e.info) == TRC_TYPE_RETIRE && e.data != 0, "retire entry holds the instruction");
    t_check(trace_matches_memory(n), "retired instruction words equal memory (W21)");

    /* ---- exception: trap entry, freeze, error log (trap port, W21) ---- */
    dbg_errlog_clear(ERR_ST_ALL);
    c = (dbg_trace_cfg_t){TRC_TRIG_NONE, TRC_TRIG_NONE, 0, 0, 0xFFFFFFFFu,
                          TRC_CTRL_LOG_TRAP | TRC_CTRL_FRZ_EXC};
    dbg_trace_setup(&c);
    trap_handler_t old = trap_set_exc_handler(t_exc);
    exc_seen = 0;
    __asm__ volatile(".word 0x00000000");
    trap_set_exc_handler(old);
    uint32_t tot = dbg_trace_total();
    for (volatile int i = 0; i < 50; i++) { }
    t_check(exc_seen == 1 && (dbg_trace_status() & TRC_ST_FROZEN), "trace frozen by the exception");
    t_check(dbg_trace_total() == tot, "frozen trace takes no new entries");
    dbg_trace_get(dbg_trace_count() - 1, &e);
    t_check(TRC_INFO_TYPE(e.info) == TRC_TYPE_TRAP && TRC_INFO_CAUSE(e.info) == EXC_ILLEGAL &&
            e.pc == exc_pc_seen, "trap entry: cause 2 at the faulting PC");
    dbg_trace_get(dbg_trace_count() - 2, &e);
    t_check(TRC_INFO_TYPE(e.info) == TRC_TYPE_RETIRE && e.pc != exc_pc_seen,
            "the trapping instruction is not recorded as retired");
    dbg_errlog_read(&el);
    t_check((el.status & ERR_ST_EXC) && el.exc_cause == EXC_ILLEGAL && el.exc_pc == exc_pc_seen &&
            el.exc_tval == 0, "error log: cause, mepc, mtval of the exception");

    /* misaligned load: mtval is the address */
    dbg_errlog_clear(ERR_ST_ALL);
    old = trap_set_exc_handler(t_exc);
    uint32_t mis = (uint32_t)(uintptr_t)dbuf + 2u, tmp;
    __asm__ volatile("lw %0, 0(%1)" : "=r"(tmp) : "r"(mis) : "memory");
    trap_set_exc_handler(old);
    (void)tmp;
    for (volatile int i = 0; i < 20; i++) { }
    dbg_errlog_read(&el);
    t_check(el.exc_cause == EXC_LOAD_MISALIGNED && el.exc_tval == mis, "error log: misaligned load, mtval = address");

    /* interrupt: trap entry with mcause bit 31, not an error-log exception */
    /* stop on the first instruction at the trap vector: the interrupt's trap
     * entry is then the second-to-last entry (the handler would overwrite it) */
    uint32_t mtvec;
    __asm__ volatile("csrr %0, mtvec" : "=r"(mtvec));
    c = (dbg_trace_cfg_t){TRC_TRIG_NONE, TRC_TRIG_PC, 0, mtvec & ~0x3Fu, 0xFFFFFFC0u, TRC_CTRL_LOG_TRAP};
    dbg_trace_setup(&c);
    dbg_errlog_clear(ERR_ST_ALL);
    uint32_t cnt0 = dbg_errlog_get(ERR_EXC_CNT);
    trap_set_irq_handler(IRQ_MSI, t_msi);
    msi_seen = 0;
    arch_irq_enable(IRQ_MSI);
    uint32_t irqs = arch_irq_save();
    arch_irq_global_enable();
    timer_set_msip(1);
    for (volatile int i = 0; i < 200 && !msi_seen; i++) { }
    arch_irq_restore(irqs);
    arch_irq_disable(IRQ_MSI);
    dbg_trace_freeze();
    int irq_entry = 0;
    uint32_t nt = dbg_trace_count();
    for (uint32_t k = 0; k < nt; k++) {
        dbg_trace_get(k, &e);
        if (TRC_INFO_TYPE(e.info) == TRC_TYPE_TRAP && TRC_INFO_CAUSE(e.info) == (CAUSE_IRQ_FLAG | IRQ_MSI) &&
            k == nt - 2 && e.data == 0)
            irq_entry++;
    }
    printf_("    msi taken %d, interrupt trap entries %d\n", msi_seen, irq_entry);
    t_check(msi_seen == 1 && irq_entry == 1, "interrupt recorded as a trap with mcause 0x80000003");
    t_check(!(dbg_errlog_status() & ERR_ST_EXC) && dbg_errlog_get(ERR_EXC_CNT) == cnt0,
            "interrupt is not logged as an exception");

    /* ---- counters: cache events, stalls (B15) ---- */
    dbg_evcnt_ctrl(0, 0);
    t_check(dbg_evcnt_clear() == 0, "event counter clear completes");
    t_check(dcache_counts_exact(), "D-cache hit / miss counts exact (B15)");
    dbg_evcnt_read(&a);
    icache_invalidate();
    for (volatile int i = 0; i < 20; i++) { }
    dbg_evcnt_settle();
    dbg_evcnt_read(&b);
    t_check(b.ic_miss > a.ic_miss && b.ic_hit > a.ic_hit, "I-cache misses after invalidate, then hits (B15)");
    dbg_evcnt_read(&a);
    {
        volatile uint32_t q = 0x7FFFFFFFu;
        for (uint32_t i = 1; i < 9; i++) q = q / (i + 2u);  /* iterative divider: stalls */
        (void)q;
    }
    dbg_evcnt_settle();
    dbg_evcnt_read(&b);
    t_check(b.stall - a.stall >= 8u * 16u, "divides stall the pipeline (stall counter)");
    cache_stats_t cs;
    dbg_evcnt_ctrl(1, 0);                   /* hold the counters for the comparison */
    dbg_evcnt_settle();
    cache_stats(&cs);
    t_check(cs.dc_hit == dbg_evcnt_get(EVC_DC_HIT) && cs.dc_miss == dbg_evcnt_get(EVC_DC_MISS) &&
            cs.ic_hit == dbg_evcnt_get(EVC_IC_HIT) && cs.ic_miss == dbg_evcnt_get(EVC_IC_MISS),
            "cache statistics come from the event counters");
    dbg_evcnt_ctrl(0, 0);

    /* counter freeze */
    dbg_evcnt_ctrl(1, 0);
    for (volatile int i = 0; i < 200; i++) { }
    dbg_evcnt_read(&a);
    for (volatile int i = 0; i < 200; i++) { }
    dbg_evcnt_read(&b);
    t_check(a.ic_hit == b.ic_hit && a.t_state[0] == b.t_state[0], "frozen counters hold");
    dbg_evcnt_ctrl(0, 1);

    /* ---- error log software error, W1C, interrupt source 4 (W23) ---- */
    dbg_errlog_clear(ERR_ST_ALL);
    trap_set_irq_handler(IRQ_MEI, t_mei);
    intc_set_enabled(IRQ_DBG_ERR);
    arch_irq_enable(IRQ_MEI);
    mei_seen = 0;
    dbg_errlog_irq_en(ERR_ST_SW_ERR);
    irqs = arch_irq_save();
    dbg_errlog_sw_error(0xC0DE0001u);
    for (volatile int i = 0; i < 20; i++) { }
    t_check((intc_pending() & IRQ_DBG_ERR) != 0, "error log interrupt pending at intc source 4 (W23)");
    arch_irq_global_enable();
    for (volatile int i = 0; i < 50 && !mei_seen; i++) { }
    arch_irq_restore(irqs);
    t_check(mei_seen == 1 && mei_src == IRQ_DBG_ERR, "error log interrupt taken through MEI");
    dbg_errlog_read(&el);
    t_check((el.status & ERR_ST_SW_ERR) && el.sw_code == 0xC0DE0001u, "error log: software error");
    dbg_errlog_clear(ERR_ST_ALL);
    dbg_errlog_irq_en(0);
    t_check(dbg_errlog_status() == 0 && !(intc_pending() & IRQ_DBG_ERR), "error log: W1C clears, interrupt drops");

    /* ---- watchdog: kick prevents the bite; bark at intc source 5 (W23) ---- */
    dbg_wdt_start(30000u, 0, 0);
    for (int k = 0; k < 10; k++) { for (volatile int i = 0; i < 100; i++) { } dbg_wdt_kick(); }
    uint32_t cnt = dbg_wdt_count();
    t_check(!(dbg_wdt_status() & WDT_ST_BITE) && cnt < 30000u && cnt > 0, "watchdog counts, kick prevents bite");
    intc_set_enabled(IRQ_WDT);
    mei_seen = 0;
    dbg_wdt_start(400u, 300u, WDT_CTRL_BARK_EN);     /* bark at COUNT <= 300 */
    irqs = arch_irq_save();
    arch_irq_global_enable();
    for (volatile int i = 0; i < 2000 && !mei_seen; i++) { }
    arch_irq_restore(irqs);
    dbg_wdt_stop();
    t_check(mei_seen == 1 && mei_src == IRQ_WDT && (dbg_wdt_status() & WDT_ST_BARK),
            "watchdog bark interrupt at intc source 5 (W23)");
    dbg_wdt_clear_status(WDT_ST_BARK | WDT_ST_BITE);
    arch_irq_disable(IRQ_MEI);
    intc_set_enabled(0);

    /* ---- power: trace intact across SLEEP, counters and error log (B16) ---- */
    if (platform_caps() & CAP_PMU) {
        trap_set_irq_handler(IRQ_MTI, timer_irq);   /* the wake timer interrupt is taken after resume */
        dbg_setup_capture();
        for (volatile int i = 0; i < 40; i++) { }
        dbg_trace_freeze();
        uint32_t t0 = dbg_trace_total();
        dbg_trace_get(0, &e);
        uint32_t pc0 = e.pc;
        dbg_evcnt_read(&a);
        uint32_t pl0 = dbg_errlog_get(ERR_PWR_LAST);
        uart_flush();
        uint32_t mie = arch_irq_mask_save(1u << IRQ_MTI);
        uint32_t sc0 = pmu_sleep_count();
        uint32_t irqs2 = arch_irq_save();     /* the wake interrupt is taken after the checks */
        timer_set_cmp(neg_abort ? timer_now() : timer_now() + 8000u);
        int r = pm_suspend(PM_SLEEP, 0);
        timer_cancel();
        arch_irq_restore(irqs2);
        arch_irq_mask_restore(mie);
        dbg_trace_get(0, &e);
        /* the SLEEP must have completed: an aborted entry is a failure, and
         * the checks below are never skipped */
        t_check(r == PM_RESUMED && pmu_sleep_count() == sc0 + 1u, "SLEEP completed and resumed (not ABORTED)");
        t_check(dbg_trace_total() == t0 && e.pc == pc0, "trace intact across SLEEP (PD_CPU off)");
        dbg_evcnt_read(&b);
        t_check(b.wake == a.wake + 1u && b.t_state[2] > a.t_state[2] && b.trans == a.trans + 2u,
                "counters: one wake, two transitions, time in SLEEP (B16)");
        uint32_t pl = dbg_errlog_get(ERR_PWR_LAST);
        t_check(ERR_PWR_COUNT(pl) == ERR_PWR_COUNT(pl0) + 2u && ERR_PWR_FROM(pl) == DBG_PS_SLEEP &&
                ERR_PWR_TO(pl) == DBG_PS_RUN && ERR_PWR_RESULT(pl) == ERR_RES_OK,
                "error log: SLEEP -> RUN completed, two transition events (B16)");
        /* IDLE and a DVFS change */
        dbg_evcnt_read(&a);
        mie = arch_irq_mask_save(1u << IRQ_MTI);
        irqs2 = arch_irq_save();
        timer_set_cmp(neg_abort ? timer_now() : timer_now() + 3000u);
        r = pm_idle();
        timer_cancel();
        arch_irq_restore(irqs2);
        arch_irq_mask_restore(mie);
        dbg_evcnt_read(&b);
        t_check(r == PM_WOKE && b.t_state[1] > a.t_state[1] && b.trans == a.trans + 2u && b.wake == a.wake,
                "counters: IDLE entry and wake, time in IDLE, no wake count (B16)");
        uint32_t op0 = pmu_cur_op(), op1 = op0 ? op0 - 1u : 1u;
        dbg_evcnt_read(&a);
        int rd = pm_set_opp(op1);
        dbg_evcnt_read(&b);
        t_check(rd == 0 && b.dvfs == a.dvfs + 1u && ((b.pstate >> 4) & 3u) == op1,
                "counters: one DVFS change, current OP (B16)");
        rd = pm_set_opp(op0);
        t_check(rd == 0, "operating point restored");
    }
    printf_("DBGTEST RESULT: %s (%d failed)\n", t_fail ? "FAIL" : "PASS", t_fail);
    return t_fail ? -1 : 0;
}

/* ================= divergence-check kernel ================= */
/* The kernel is fw/debug/dbg_div_kernel.S (shared with the Spike harness). */
void dbg_div_kernel(void);

static int div_test(void)
{
    uint32_t s = arch_irq_save();
    dbg_trace_cfg_t c = {TRC_TRIG_PC, TRC_TRIG_NONE, (uint32_t)(uintptr_t)dbg_div_kernel, 0, 0xFFFFFFFFu, 0};
    dbg_trace_setup(&c);
    dbg_div_kernel();
    arch_irq_restore(s);
    printf_("DIVTEST kernel=0x%08x\n", (unsigned)(uintptr_t)dbg_div_kernel);
    dbg_crash_dump("request", 0);
    return 0;
}

/* ================= run control ================= */
static void crash_after(int is_exc);

static int run_test(uint32_t test, uint32_t seed, uint32_t iters, uint32_t flags)
{
    volatile dbg_mbox_t *mb = DBG_MBOX;
    mb->magic = DBG_MBOX_MAGIC; mb->seed = seed; mb->test_id = test;
    mb->flags = flags; mb->iters = iters; mb->state = DBG_ST_RUNNING;
    dbg_crash_seed = seed;
    quiet = (flags & DBG_F_QUIET) != 0;
    neg_abort = (flags & DBG_F_NEG_ABORT) != 0;
    if (neg_abort) puts_("DBGRUN NEGATIVE TEST: every sleep sees a pending wake (aborted)\n");
    printf_("DBGRUN test=%u seed=0x%08x\n", (unsigned)test, (unsigned)seed);
    dbg_errlog_clear(ERR_ST_ALL);
    dbg_setup_capture();
    int r;
    switch (test) {
    case DBG_T_STRESS:   r = stress(iters ? iters : 40u, flags); break;
    case DBG_T_DRV:      r = drv_test(); break;
    case DBG_T_CRASH_ILLEGAL:  inject(0); r = -1; break;
    case DBG_T_CRASH_MISALIGN: inject(1); r = -1; break;
    case DBG_T_DIVTEST:  r = div_test(); break;
    case DBG_T_HANG:
        dbg_wdt_start(60000u, 0, WDT_CTRL_RST_EN);
        inject(3); r = -1; break;
    default: puts_("ERR test id\n"); r = -1; break;
    }
    mb->state = r ? DBG_ST_FAIL : DBG_ST_PASS;
    return r;
}

static int cmd_dbg(int argc, char **argv)
{
    (void)argc; (void)argv;
    dbg_crash_dump("request", 0);
    return 0;
}

static int cmd_dbgrun(int argc, char **argv)
{
    uint32_t t, s, it = 0, fl = 0;
    if (argc < 3 || parse_u32(argv[1], &t) || parse_u32(argv[2], &s) ||
        (argc > 3 && parse_u32(argv[3], &it)) || (argc > 4 && parse_u32(argv[4], &fl))) {
        puts_("ERR usage: dbgrun <test> <seed> [iters] [flags]\n");
        return -1;
    }
    int r = run_test(t, s, it, fl);
    printf_("DBGRUN RESULT: %s\n", r ? "FAIL" : "PASS");
    return r;
}

static const mon_cmd_t dbg_cmds[] = {
    {"sleep",  "<state> <t|uart>",       "idle|sleep|deep for t ticks or until UART input", cmd_sleep},
    {"opp",    "<0..2>",                 "set CPU operating point",    cmd_opp},
    {"dbg",    "",                       "dump debug state",           cmd_dbg},
    {"dbgrun", "<t> <seed> [it] [fl]",   "1 stress 2 drv 3 ill 4 mis 5 hang 6 div", cmd_dbgrun},
    {"exit",   "[code]",                 "end the run (PASS / FAIL)",  cmd_exit},
};

static void crash_after(int is_exc)
{
    uint32_t test = DBG_MBOX->test_id;
    dbg_errlog_t e;
    (void)is_exc;
    dbg_errlog_read(&e);
    /* expected crashes of the demonstration tests are a PASS */
    if ((test == DBG_T_CRASH_ILLEGAL && (e.status & ERR_ST_EXC) && e.exc_cause == EXC_ILLEGAL) ||
        (test == DBG_T_CRASH_MISALIGN && (e.status & ERR_ST_EXC) && e.exc_cause == EXC_LOAD_MISALIGNED)) {
        printf_("DBGTEST expected crash (cause 0x%x): PASS\n", (unsigned)e.exc_cause);
        DBG_MBOX->state = DBG_ST_PASS;
        finish(0);
        puts_("DBGRUN RESULT: PASS\n");
    } else {
        DBG_MBOX->state = DBG_ST_FAIL;
        finish(0xDB6C0000u | (e.exc_cause & 0xFFu));
        puts_("DBGRUN RESULT: FAIL\n");
    }
    /* the crashed context cannot be resumed: back to the monitor (the trap
     * handler's stack frame is abandoned) */
    monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
}

int main(void)
{
    arch_init();
    platform_init();
    dbg_crash_after = crash_after;
    uint32_t arg = platform_boot_arg();
    sim_mode = (arg & BOOTARG_AUTORUN) != 0;
    printf_("[DBGAPP] debug application, platform %s, cpu %s, dbg base 0x%08x, reset cause %u\n",
            PLATFORM_NAME, ARCH_NAME, (unsigned)DBG_BASE, (unsigned)HANDOFF->rst_cause);
    if (!dbg_present()) {
        puts_("[DBGAPP] debug hardware not found\n");
        finish(0xDB6C00FFu);
        monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
    }
    dbg_crash_install();
    volatile dbg_mbox_t *mb = DBG_MBOX;
    dbg_crash_seed = mb->magic == DBG_MBOX_MAGIC ? mb->seed : 0;

    /* post-mortem: a watchdog reset or an error from before this boot */
    if (dbg_crash_check_boot()) {
        uint32_t st = dbg_errlog_status();
        int expected = mb->magic == DBG_MBOX_MAGIC && mb->test_id == DBG_T_HANG &&
                       (st & ERR_ST_WDT_RST) && mb->state == DBG_ST_RUNNING &&
                       HANDOFF->rst_cause == RST_WDT;
        dbg_errlog_clear(ERR_ST_ALL);
        mb->state = expected ? DBG_ST_PASS : DBG_ST_FAIL;
        if (expected) printf_("DBGTEST hang detected by the watchdog: PASS\n");
        printf_("DBGRUN RESULT: %s\n", expected ? "PASS" : "FAIL");
        finish(expected ? 0 : 0xDB6C0057u);
        monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
    }

    if (sim_mode) {
        int r = run_test(BOOTARG_TEST(arg), platform_host_arg(0), platform_host_arg(1), platform_host_arg(2));
        finish(r ? 0xDB6C0001u : 0);
    } else if (mb->magic == DBG_MBOX_MAGIC && mb->state == DBG_ST_REQUEST) {
        int r = run_test(mb->test_id, mb->seed, mb->iters, mb->flags);
        printf_("DBGRUN RESULT: %s\n", r ? "FAIL" : "PASS");
    }
    monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
}
