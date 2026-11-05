/*
 * Debug application: seeded random stress test, debug-driver self test,
 * crash / hang demonstrations, and debug commands added to the Session 3
 * UART monitor (monitor_run extension API).
 *
 * Run control (first match wins):
 *   1. mailbox in RAM (dbg_mbox.h), written by the bench through the monitor
 *   2. integration testbench control registers (SIMCTRL_SEED etc.)
 *   3. otherwise: UART monitor with the commands below
 *
 * Monitor commands added here:
 *   dbg                         dump trace / counters / error log (crash format)
 *   dbgrun <test> <seed> [iters] [flags]   1 stress, 2 driver test, 3 illegal,
 *                               4 misaligned, 5 hang (watchdog)
 *   exit [code]                 end simulation
 */
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"
#include "pm.h"
#include "trap.h"
#include "dbg_drv.h"
#include "dbg_crash.h"
#include "dbg_mbox.h"

#define MBOX ((volatile dbg_mbox_t *)(uintptr_t)(RAM_BASE + RAM_UNCACHED_OFFSET + DBG_MBOX_OFFSET))

static int      sim_mode;              /* running under a testbench: exit when done */
static uint32_t rng;
static int      quiet;

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
    dbg_evcnt_clear();
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
    dcache_clean_range(&buf[off], len * 4u);
    volatile uint32_t *u = UNCACHED(&buf[off]);
    for (uint32_t i = 0; i < len; i++)
        if (u[i] != buf[off + i]) return fail("uncached view after clean", u[i], buf[off + i]);
    golden = crc32(buf, sizeof(buf));
    return 0;
}

static int op_flush(uint32_t arg)
{
    switch (arg % 4u) {
    case 0: dcache_clean_all(); break;
    case 1: dcache_flush_all(); break;
    case 2: icache_inv_all(); break;
    default: dcache_flush_range(&buf[arg % BUF_WORDS], 256); break;
    }
    __asm__ volatile("fence" ::: "memory");
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

static int op_sleep(uint32_t arg)
{
    static const enum pm_state sts[3] = {PM_IDLE, PM_SLEEP, PM_DEEP_SLEEP};
    uint32_t si = arg % 3u;
    uint32_t ticks = 6000u + (arg >> 8) % 6000u;
    if (!pmu_present()) return 0;
    cov_ps_op[si][pmu_cur_op() % 3u]++;
    uart_flush();
    dcache_clean_all();
    pmu_set_wake(PMU_WAKE_MTIP);
    timer_set_cmp(timer_now() + ticks);
    int r = pm_suspend(sts[si], 0);
    timer_cancel();
    pmu_set_wake(0);
    if (r < 0) return fail("pm_suspend result", (uint32_t)r, 0);
    uint32_t c = crc32(buf, sizeof(buf));
    if (c != golden) return fail("RAM CRC after wake", c, golden);
    if (!quiet) printf_("  woke result=%d\n", r);
    return 0;
}

static int op_dvfs(uint32_t arg)
{
    uint32_t op = arg % 3u;
    if (!pmu_present()) return 0;
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
    case 2:
        if (arch_caps() & CAP_ACCFAULT) { (void)*(volatile uint32_t *)0x7FFFFFF0u; break; }
        __asm__ volatile(".word 0x00000000"); break;
    default:                                                        /* hang */
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
    for (unsigned i = 0; i < N_OPS; i++) printf_("COV op=%s n=%u\n", op_name[i], (unsigned)op_hits[i]);
    for (unsigned s = 0; s < 3; s++)
        for (unsigned o = 0; o < 3; o++)
            printf_("COV sleep_state=%u opp=%u n=%u\n", s, o, (unsigned)cov_ps_op[s][o]);
    printf_("STRESS PASS seed=0x%08x iters=%u\n", (unsigned)dbg_crash_seed, (unsigned)iters);
    return 0;
}

/* ================= driver self test ================= */
static int t_fail;
static void t_check(int ok, const char *what)
{
    printf_("[DBGT] %-40s %s\n", what, ok ? "PASS" : "FAIL");
    if (!ok) t_fail++;
}

static __attribute__((noinline)) uint32_t marker_a(uint32_t x) { return x * 3u + 1u; }
static __attribute__((noinline)) uint32_t marker_b(uint32_t x) { return x ^ 0x5Au; }
static volatile int exc_seen;
static void t_exc(trap_frame_t *f) { exc_seen++; f->epc += 4; }

static int drv_test(void)
{
    dbg_trace_entry_t e;
    t_check(dbg_present(), "all four blocks present (ID)");
    /* trace start / stop on PC match */
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
    /* freeze on exception, error log records it */
    dbg_errlog_clear(ERR_ST_ALL);
    c = (dbg_trace_cfg_t){TRC_TRIG_NONE, TRC_TRIG_NONE, 0, 0, 0xFFFFFFFFu,
                          TRC_CTRL_LOG_TRAP | TRC_CTRL_FRZ_EXC};
    dbg_trace_setup(&c);
    trap_handler_t old = trap_set_exc_handler(t_exc);
    __asm__ volatile(".word 0x00000000");
    trap_set_exc_handler(old);
    uint32_t tot = dbg_trace_total();
    for (volatile int i = 0; i < 50; i++) { }
    t_check(exc_seen == 1 && (dbg_trace_status() & TRC_ST_FROZEN), "trace frozen by the exception");
    t_check(dbg_trace_total() == tot, "frozen trace takes no new entries");
    dbg_trace_get(dbg_trace_count() - 1, &e);
    t_check(TRC_INFO_TYPE(e.info) == TRC_TYPE_TRAP, "last entry is the trap");
    t_check(dbg_errlog_status() & ERR_ST_EXC, "error log: EXC sticky set");
    /* counters */
    dbg_evcnt_ctrl(0, 0);
    dbg_evcnt_clear();
    for (volatile int i = 0; i < 200; i++) { }
    dbg_evcnt_t a, b;
    dbg_evcnt_read(&a);
    t_check(a.ic_hit + a.ic_miss > 0 && a.t_state[0] > 0, "event counters count");
    dbg_evcnt_ctrl(1, 0);
    for (volatile int i = 0; i < 200; i++) { }
    dbg_evcnt_read(&b);
    t_check(a.ic_hit <= b.ic_hit, "counters monotonic");
    dbg_evcnt_read(&a);
    for (volatile int i = 0; i < 200; i++) { }
    dbg_evcnt_read(&b);
    t_check(a.ic_hit == b.ic_hit && a.t_state[0] == b.t_state[0], "frozen counters hold");
    dbg_evcnt_ctrl(0, 1);
    /* error log software error + W1C */
    dbg_errlog_sw_error(0xC0DE0001u);
    dbg_errlog_t el;
    dbg_errlog_read(&el);
    t_check((el.status & ERR_ST_SW_ERR) && el.sw_code == 0xC0DE0001u, "error log: software error");
    dbg_errlog_clear(ERR_ST_ALL);
    t_check(dbg_errlog_status() == 0, "error log: W1C clears");
    /* watchdog kicked does not bite */
    dbg_wdt_start(30000u, 0, 0);
    for (int k = 0; k < 10; k++) { for (volatile int i = 0; i < 100; i++) { } dbg_wdt_kick(); }
    uint32_t cnt = dbg_wdt_count();
    t_check(!(dbg_wdt_status() & WDT_ST_BITE) && cnt < 30000u && cnt > 0, "watchdog counts, kick prevents bite");
    dbg_wdt_stop();
    /* trace readable and intact after PD_CPU power-down */
    if (pmu_present()) {
        dbg_setup_capture();
        for (volatile int i = 0; i < 40; i++) { }
        dbg_trace_freeze();
        uint32_t t0 = dbg_trace_total();
        dbg_trace_get(0, &e);
        uint32_t pc0 = e.pc;
        uart_flush();
        pmu_set_wake(PMU_WAKE_MTIP);
        timer_set_cmp(timer_now() + 8000u);
        int r = pm_suspend(PM_SLEEP, 0);
        timer_cancel();
        pmu_set_wake(0);
        dbg_trace_get(0, &e);
        t_check(r == PM_RESUMED || r == PM_ABORTED, "sleep / resume");
        t_check(dbg_trace_total() == t0 && e.pc == pc0, "trace intact across SLEEP (PD_CPU off)");
        dbg_evcnt_read(&a);
        t_check(r != PM_RESUMED || (a.wake >= 1 && a.t_state[2] > 0), "counters: wake count, time in SLEEP");
    }
    printf_("DBGTEST RESULT: %s (%d failed)\n", t_fail ? "FAIL" : "PASS", t_fail);
    return t_fail ? -1 : 0;
}

/* ================= divergence-check kernel ================= */
/* Pure RV32IM instruction stream (no I/O, no platform-dependent data), so
 * Spike started at dbg_div_kernel executes exactly what the DUT retired.
 * a0 = trace CTRL address: the kernel ends by freezing the trace, followed
 * by nops that cover the freeze latency. tools/dbg_decode.py --spike-log
 * compares the dumped trace with the Spike commit log. */
__asm__(
    "  .section .text.dbg_div, \"ax\"\n"
    "  .globl dbg_div_kernel\n"
    "dbg_div_kernel:\n"
    "  li   t0, 0x12345678\n"
    "  li   t1, 0\n"
    "  li   t2, 40\n"
    "1:\n"
    "  mul  t3, t0, t0\n"
    "  xor  t0, t0, t3\n"
    "  srli t3, t0, 7\n"
    "  add  t1, t1, t3\n"
    "  divu t4, t1, t2\n"
    "  remu t5, t0, t2\n"
    "  add  t0, t0, t4\n"
    "  addi t2, t2, -1\n"
    "  bnez t2, 1b\n"
    "  li   t6, 4\n"
    "  sw   t6, 0(a0)\n"
    "  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n"
    "  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n  nop\n"
    "  ret\n"
    "  .text\n");
void dbg_div_kernel(uint32_t trace_ctrl_addr);

static int div_test(void)
{
    uint32_t s = arch_irq_save();
    dbg_trace_cfg_t c = {TRC_TRIG_NONE, TRC_TRIG_NONE, 0, 0, 0xFFFFFFFFu, 0};
    dbg_trace_setup(&c);
    dbg_div_kernel(DBG_TRACE_BASE + TRC_CTRL);
    arch_irq_restore(s);
    printf_("DIVTEST kernel=0x%08x\n", (unsigned)(uintptr_t)dbg_div_kernel);
    dbg_crash_dump("request", 0);
    return 0;
}

/* ================= run control ================= */
static void crash_after(int is_exc)
{
    uint32_t test = MBOX->test_id;
    uint32_t cause = 0;
    (void)is_exc;
    dbg_errlog_t e;
    dbg_errlog_read(&e);
    cause = e.exc_cause;
    /* expected crashes of the demonstration tests are a PASS */
    if ((test == DBG_T_CRASH_ILLEGAL && (e.status & ERR_ST_EXC)) ||
        (test == DBG_T_CRASH_MISALIGN && (e.status & ERR_ST_EXC))) {
        printf_("DBGTEST expected crash (cause 0x%x): PASS\n", (unsigned)cause);
        MBOX->state = 2;
        finish(0);
    } else {
        MBOX->state = 3;
        finish(0xDB6C0000u | (cause & 0xFFu));
    }
    monitor_run(0, 0);
}

static int run_test(uint32_t test, uint32_t seed, uint32_t iters, uint32_t flags)
{
    MBOX->magic = DBG_MBOX_MAGIC; MBOX->seed = seed; MBOX->test_id = test;
    MBOX->flags = flags; MBOX->iters = iters; MBOX->state = 1;
    dbg_crash_seed = seed;
    quiet = (flags & DBG_F_QUIET) != 0;
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
    default: printf_("ERR test id\n"); r = -1; break;
    }
    MBOX->state = r ? 3 : 2;
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
    if (argc < 3 || parse_u32(argv[1], &t) || parse_u32(argv[2], &s)) {
        puts_("ERR usage: dbgrun <test> <seed> [iters] [flags]\n");
        return -1;
    }
    if (argc > 3) parse_u32(argv[3], &it);
    if (argc > 4) parse_u32(argv[4], &fl);
    int r = run_test(t, s, it, fl);
    printf_("DBGRUN RESULT: %s\n", r ? "FAIL" : "PASS");
    return r;
}

static int cmd_exit(int argc, char **argv)
{
    uint32_t code = 0;
    if (argc > 1) parse_u32(argv[1], &code);
    platform_exit(code);
}

static const mon_cmd_t dbg_cmds[] = {
    {"dbg",    "",                       "dump debug state",           cmd_dbg},
    {"dbgrun", "<t> <seed> [it] [fl]",   "1 stress 2 drv 3 ill 4 mis 5 hang 6 div", cmd_dbgrun},
    {"exit",   "[code]",                 "end simulation",             cmd_exit},
};

int main(void)
{
    arch_init();
    platform_init();
    dbg_crash_after = crash_after;
    printf_("[DBGAPP] debug application, platform %s, cpu %s, dbg base 0x%08x\n", PLATFORM_NAME,
            ARCH_NAME, (unsigned)DBG_BASE);
    if (!dbg_present()) {
        puts_("[DBGAPP] debug hardware not found\n");
        finish(0xDB6C00FFu);
        monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
    }
    dbg_crash_install();
    dbg_crash_seed = MBOX->magic == DBG_MBOX_MAGIC ? MBOX->seed : 0;

    /* integration testbench: run control registers */
    uint32_t a = REG32(SIMCTRL_BASE + SIMCTRL_ARG);
    if ((a & SIMCTRL_ARG_PRESENT) && REG32(SIMCTRL_BASE + SIMCTRL_DBG_MAGIC) == DBG_MBOX_MAGIC &&
        !(a & SIMCTRL_ARG_MONITOR))
        sim_mode = 1;

    /* post-mortem: a watchdog reset or an error from before this boot */
    if (dbg_crash_check_boot()) {
        uint32_t st = dbg_errlog_status();
        int expected = MBOX->magic == DBG_MBOX_MAGIC && MBOX->test_id == DBG_T_HANG &&
                       (st & ERR_ST_WDT_RST) && MBOX->state == 1;
        dbg_errlog_clear(ERR_ST_ALL);
        MBOX->state = expected ? 2 : 3;
        if (expected) printf_("DBGTEST hang detected by the watchdog: PASS\n");
        finish(expected ? 0 : 0xDB6C0057u);
        monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
    }

    if (sim_mode) {
        uint32_t t = a & 0xFFFFu;
        int r = run_test(t, REG32(SIMCTRL_BASE + SIMCTRL_SEED), REG32(SIMCTRL_BASE + SIMCTRL_ITERS),
                         REG32(SIMCTRL_BASE + SIMCTRL_FLAGS));
        finish(r ? 0xDB6C0001u : 0);
    } else if (MBOX->magic == DBG_MBOX_MAGIC && MBOX->state == 0) {
        int r = run_test(MBOX->test_id, MBOX->seed, MBOX->iters, MBOX->flags);
        printf_("DBGRUN RESULT: %s\n", r ? "FAIL" : "PASS");
    }
    monitor_run(dbg_cmds, ARRAY_SIZE(dbg_cmds));
}
