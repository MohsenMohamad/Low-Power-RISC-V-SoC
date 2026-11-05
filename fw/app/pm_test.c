/*
 * SoC power-management integration test (stage 1, ported to the shared
 * drivers, pm layer and boot ROM in stage 2). Loaded as an application image;
 * the boot ROM starts it.
 *
 * Self-checking: prints one line per step and finishes with "PASS" or
 * "FAIL 0x<n>" on the UART (platform_exit). The testbench decodes the UART
 * and checks the power-state coverage goals (dv/regress/soc_pm_test.goals).
 *
 * Covers: RUN<->IDLE (wake timer, machine timer), a wake event already
 * pending at WFI (no transition: reported as ABORTED), all six DVFS
 * operating-point changes (with a CPU-vs-AON clock ratio check), RUN<->SLEEP,
 * RUN<->DEEP_SLEEP with RAM retention checks, wake from the external wake
 * pin, a refused power-down with a dirty D-cache, and a sleep/wake stress
 * loop mixing all of them.
 */
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "platform_api.h"
#include "pm.h"

static uint32_t fails;
static uint32_t retained_buf[256];
static volatile uint32_t retained_marker;

static void check(int cond, const char *what, uint32_t val)
{
    if (!cond) {
        fails++;
        printf_("  ERR %s 0x%08x\n", what, (unsigned)val);
    }
}

static void step(const char *name)
{
    printf_("[step] %s\n", name);
}

/* Wake-up delays in clk_aon cycles. They must exceed the low-power entry time
 * at the slowest operating point (OP0) including the D-cache clean in
 * pm_suspend(). After a SLEEP resume both caches are cold and every line
 * refill crosses the CPU->AON bridge as four single-beat reads; at OP0 the
 * stress loop measured ~5100 clk_aon cycles from the timer start to WFI. The
 * D-cache is cleaned before each timer is armed, so the clean inside
 * pm_suspend() finds (almost) nothing dirty. */
#define WAKE_IDLE   4000u
#define WAKE_OFF    12000u
#define WAKE_STRESS 12000u

static uint32_t checksum(void)
{
    uint32_t s = 0x12345678u;
    for (unsigned i = 0; i < ARRAY_SIZE(retained_buf); i++) s = (s << 5 | s >> 27) ^ retained_buf[i];
    return s;
}

/* CPU cycles per 64 AON cycles, measured with mcycle vs mtime. */
static uint32_t clk_ratio(void)
{
    uint64_t t0 = timer_now();
    uint64_t c0 = arch_cycles();
    while (timer_now() - t0 < 256u) ;
    uint64_t c1 = arch_cycles();
    uint64_t t1 = timer_now();
    return (uint32_t)(((c1 - c0) * 64u) / (t1 - t0));
}

static void test_idle_wake_timer(void)
{
    step("idle/wake-timer");
    intc_set_enabled(IRQ_WTIMER);
    check(dcache_clean() == 0, "clean", 0);
    wtimer_start(WAKE_IDLE, 0);
    int r = pm_suspend(PM_IDLE, 0);
    check(r == PM_WOKE, "idle completed", (uint32_t)r);
    check(pmu_wake_cause() & WAKE_MEIP, "wake cause", pmu_wake_cause());
    check(intc_pending() & IRQ_WTIMER, "wt pending", intc_pending());
    wtimer_stop();
    intc_set_enabled(0);
}

static void test_idle_mtimer(void)
{
    step("idle/mtimer");
    check(dcache_clean() == 0, "clean", 0);
    timer_set_cmp(timer_now() + WAKE_IDLE);
    int r = pm_suspend(PM_IDLE, 0);
    check(r == PM_WOKE, "idle completed", (uint32_t)r);
    check(pmu_wake_cause() & WAKE_MTIP, "wake cause", pmu_wake_cause());
    timer_cancel();
}

/* A wake event already pending and enabled at WFI: the core never reports
 * core_sleep, so no IDLE entry happens. pm_idle() must report that as
 * ABORTED, never as a completed transition (doc/SPEC.md). */
static void test_idle_msip_pending(void)
{
    step("idle/msip-already-pending");
    timer_set_msip(1);
    int r = pm_suspend(PM_IDLE, 0);
    check(r == PM_ABORTED, "no transition reported as aborted", (uint32_t)r);
    timer_set_msip(0);
}

static uint32_t ratio_at[3];

static void dvfs_to(uint32_t op)
{
    int r = pm_set_opp(op);
    uint32_t st = pmu_status();
    check(r == 0, "dvfs returned", (uint32_t)r);
    check(PMU_ST_CUR_OP(st) == op, "dvfs op", st);
    check(!(st & PMU_ST_DVFS_PEND), "dvfs pending", st);
    check(pmu_read(PMU_VSEL) == op, "vsel", pmu_read(PMU_VSEL));
    ratio_at[op] = clk_ratio();
    printf_("  op %u cpu/aon*64 = 0x%08x\n", (unsigned)op, (unsigned)ratio_at[op]);
}

static void test_dvfs(void)
{
    step("dvfs/all-transitions");
    check(pmu_cur_op() == 2, "start op", pmu_cur_op());
    /* from OP2: 2->1, 1->0, 0->2, 2->0, 0->1, 1->2 covers all six ordered pairs */
    static const uint8_t seq[6] = {1, 0, 2, 0, 1, 2};
    for (int i = 0; i < 6; i++) dvfs_to(seq[i]);
    check(ratio_at[0] < ratio_at[1] && ratio_at[1] < ratio_at[2], "freq order", ratio_at[0]);
}

static void test_power_off(enum pm_state st, const char *name, int use_ext_pin)
{
    step(name);
    uint32_t cnt0 = pmu_sleep_count();
    for (unsigned i = 0; i < ARRAY_SIZE(retained_buf); i++) retained_buf[i] = i * 0x9E3779B9u + cnt0;
    uint32_t sum = checksum();
    volatile uint32_t on_stack = 0xA5A55A5Au ^ cnt0;
    retained_marker = 0xCAFEBABEu;

    uart_flush();
    check(dcache_clean() == 0, "clean", 0);
    if (use_ext_pin) {
        intc_set_enabled(IRQ_EXT_WAKE);
        wtimer_stop();
    } else {
        intc_set_enabled(IRQ_WTIMER);
        wtimer_start(WAKE_OFF, 0);
    }
    int r = pm_suspend(st, 0);
    volatile handoff_t *h = HANDOFF;

    check(r == PM_RESUMED, "resumed", (uint32_t)r);
    check(h->boot_status == BOOT_RESUMED, "boot status", h->boot_status);
    check(h->rst_cause == (st == PM_DEEP_SLEEP ? RST_DEEP : RST_SLEEP), "reset cause", h->rst_cause);
    check(h->pmu_status & PMU_ST_RESUME, "PMU resume flag at ROM entry", h->pmu_status);
    check(((h->pmu_status & PMU_ST_RESUME_DEEP) != 0) == (st == PM_DEEP_SLEEP), "deep flag", h->pmu_status);
    check(pmu_sleep_count() == cnt0 + 1, "sleep count", pmu_sleep_count());
    check(retained_marker == 0xCAFEBABEu, "marker", retained_marker);
    check(on_stack == (0xA5A55A5Au ^ cnt0), "stack", on_stack);
    check(checksum() == sum, "ram checksum", checksum());
    check(pmu_wake_cause() & WAKE_MEIP, "wake cause", pmu_wake_cause());
    check(!(pmu_status() & PMU_ST_RESUME), "resume flag cleared", pmu_status());
    wtimer_stop();
    intc_set_enabled(0);
}

/* The PMU must refuse SLEEP while the D-cache holds dirty lines: the CPU
 * stays powered (clock gated), STATUS.ERR_DIRTY is set, SLEEP_CNT does not
 * change and the dirty data is intact after the wake-up. pm_suspend reports
 * the refusal as ABORTED. */
static void test_dirty_refusal(void)
{
    step("sleep/dirty-dcache-refused");
    uint32_t cnt0 = pmu_sleep_count();
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    for (unsigned i = 0; i < 16; i++) retained_buf[i] = 0x51EE0000u + i;
    intc_set_enabled(IRQ_WTIMER);
    wtimer_start(WAKE_OFF, 0);
    int r = pm_suspend(PM_SLEEP, PM_F_NO_CLEAN);
    uint32_t s = pmu_status();
    check(r == PM_ABORTED, "refused sleep reported as aborted", (uint32_t)r);
    check(s & PMU_ST_ERR_DIRTY, "err_dirty", s);
    check(!(s & PMU_ST_RESUME), "no resume", s);
    check(pmu_sleep_count() == cnt0, "sleep count unchanged", pmu_sleep_count());
    for (unsigned i = 0; i < 16; i++)
        check(retained_buf[i] == 0x51EE0000u + i, "dirty data", retained_buf[i]);
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    wtimer_stop();
    intc_set_enabled(0);
}

static void test_stress(int iterations)
{
    step("stress/sleep-wake-loop");
    static const uint8_t op_seq[5] = {0, 2, 1, 1, 2};
    for (int i = 0; i < iterations; i++) {
        enum pm_state st = (enum pm_state)(i % 3);
        if (st == PM_IDLE) pmu_write(PMU_DVFS, op_seq[i % 5]);   /* applied during the IDLE */
        uint32_t cnt0 = pmu_sleep_count();
        retained_marker = 0x1000u + (uint32_t)i;
        intc_set_enabled(IRQ_WTIMER);
        check(dcache_clean() == 0, "clean", (uint32_t)i);
        wtimer_start(WAKE_STRESS + 37u * (uint32_t)i, 0);
        int r = pm_suspend(st, 0);
        check(r == (st == PM_IDLE ? PM_WOKE : PM_RESUMED), "stress transition completed", (uint32_t)i);
        check(retained_marker == 0x1000u + (uint32_t)i, "stress marker", retained_marker);
        check(pmu_sleep_count() == cnt0 + (st != PM_IDLE), "stress count", (uint32_t)i);
        if (st == PM_IDLE)
            check(pmu_cur_op() == op_seq[i % 5], "stress op", pmu_status());
        pmu_clear_status(PMU_ST_DVFS_DONE);
        wtimer_stop();
    }
    intc_set_enabled(0);
}

int main(void)
{
    arch_init();
    puts_("\nlp-soc pm_test\n");
    /* wake sources: interrupt controller, machine timer, software interrupt
     * (enabled in mie, mstatus.MIE = 0: no trap is taken) */
    arch_irq_enable(IRQ_MEI);
    arch_irq_enable(IRQ_MTI);
    arch_irq_enable(IRQ_MSI);
    check(pmu_cur_op() == 2, "reset op", pmu_status());
    check(pmu_sleep_count() == 0, "reset sleep count", pmu_sleep_count());

    test_idle_wake_timer();
    test_idle_mtimer();
    test_idle_msip_pending();
    test_dvfs();
    test_power_off(PM_SLEEP, "sleep/wake-timer", 0);
    test_power_off(PM_DEEP_SLEEP, "deep-sleep/wake-timer", 0);
    test_power_off(PM_SLEEP, "sleep/ext-wake-pin", 1);
    test_power_off(PM_DEEP_SLEEP, "deep-sleep/ext-wake-pin", 1);
    test_dirty_refusal();
    test_stress(12);

    platform_exit(fails);
}
