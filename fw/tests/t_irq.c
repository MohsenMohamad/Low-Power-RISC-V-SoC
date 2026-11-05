/* Validation: interrupts (machine timer, software, external through the
 * interrupt controller), masking, WFI.
 *
 * Interrupt controller (doc/SOC_REGMAP.md, audit B06/W14): level-sensitive
 * sources cleared at their origin (0 UART, 1 wake timer, 2 PMU DVFS_DONE,
 * 3 external wake pin); no software-pending or claim register, so external
 * interrupts are raised with real sources (UART TX-idle, wake timer). */
#include "test.h"
#include "arch.h"
#include "trap.h"
#include "drivers.h"
#include "platform_api.h"
#include "pm.h"

#define WAIT_TICKS 20000u

static volatile uint32_t mti_count, msi_count, mei_count;
static volatile uint64_t mti_time;
static volatile int      mei_order[8];

static void mti_handler(trap_frame_t *f)
{
    (void)f;
    mti_time  = timer_now();
    mti_count = mti_count + 1;
    timer_cancel();                          /* level interrupt: clear source */
}

static void msi_handler(trap_frame_t *f)
{
    (void)f;
    msi_count = msi_count + 1;
    timer_set_msip(0);
}

/* Clears each source at its origin. */
static void mei_handler(trap_frame_t *f)
{
    (void)f;
    int id = intc_claim();
    if (mei_count < 8) mei_order[mei_count] = id;
    mei_count = mei_count + 1;
    if (id == INTC_SRC_UART) uart_set_ie(0);
    else if (id == INTC_SRC_WTIMER) wtimer_stop();
    else intc_set_enabled(0);                /* unexpected source: no storm */
}

static int wait_flag(volatile uint32_t *flag, uint32_t want)
{
    uint64_t end = timer_now() + WAIT_TICKS;
    while (*flag < want && timer_now() < end) ;
    return *flag >= want;
}

static void irq_off(void)
{
    (void)arch_irq_save();
    arch_irq_disable(IRQ_MTI);
    arch_irq_disable(IRQ_MSI);
    arch_irq_disable(IRQ_MEI);
}

static int t_timer_irq(void)
{
    trap_set_irq_handler(IRQ_MTI, mti_handler);
    mti_count = 0;
    uint64_t due = timer_now() + 300;
    timer_set_cmp(due);
    arch_irq_enable(IRQ_MTI);
    arch_irq_global_enable();
    int ok = wait_flag(&mti_count, 1);
    timer_delay(100);
    irq_off();
    CHECK(ok);
    CHECK_EQ(mti_count, 1);                  /* exactly once: source cleared */
    CHECK(mti_time >= due);
    return TEST_PASS;
}
TEST(20, "irq_timer", CAP_CLINT, t_timer_irq);

static int t_timer_masked(void)
{
    trap_set_irq_handler(IRQ_MTI, mti_handler);
    mti_count = 0;
    arch_irq_enable(IRQ_MTI);                /* source enabled, global off */
    timer_set_cmp(timer_now() + 50);
    timer_delay(400);
    CHECK_EQ(mti_count, 0);                  /* pending but masked */
    arch_irq_global_enable();                /* taken immediately */
    int ok = wait_flag(&mti_count, 1);
    irq_off();
    CHECK(ok);
    CHECK_EQ(mti_count, 1);
    /* per-source disable */
    mti_count = 0;
    arch_irq_global_enable();
    timer_set_cmp(timer_now() + 50);
    timer_delay(400);
    CHECK_EQ(mti_count, 0);
    timer_cancel();
    irq_off();
    return TEST_PASS;
}
TEST(21, "irq_timer_masking", CAP_CLINT, t_timer_masked);

static int t_soft_irq(void)
{
    trap_set_irq_handler(IRQ_MSI, msi_handler);
    msi_count = 0;
    arch_irq_enable(IRQ_MSI);
    arch_irq_global_enable();
    timer_set_msip(1);
    int ok = wait_flag(&msi_count, 1);
    irq_off();
    CHECK(ok);
    CHECK_EQ(msi_count, 1);
    CHECK_EQ(timer_get_msip(), 0);
    return TEST_PASS;
}
TEST(22, "irq_software", CAP_CLINT, t_soft_irq);

static int t_ext_irq(void)
{
    trap_set_irq_handler(IRQ_MEI, mei_handler);
    mei_count = 0;
    intc_set_enabled(IRQ_WTIMER);
    arch_irq_enable(IRQ_MEI);
    arch_irq_global_enable();
    wtimer_start(200, 0);
    int ok = wait_flag(&mei_count, 1);
    timer_delay(100);
    irq_off();
    intc_set_enabled(0);
    CHECK(ok);
    CHECK_EQ(mei_count, 1);                  /* level source cleared once */
    CHECK_EQ(mei_order[0], INTC_SRC_WTIMER);
    CHECK_EQ(intc_pending() & IRQ_WTIMER, 0);
    return TEST_PASS;
}
TEST(23, "irq_external_intc", CAP_INTC | CAP_WTIMER, t_ext_irq);

static int t_intc_priority(void)
{
    trap_set_irq_handler(IRQ_MEI, mei_handler);
    mei_count = 0;
    /* raise two sources while masked: wake timer expired, UART TX idle */
    uart_flush();
    wtimer_start(10, 0);
    timer_delay(40);
    uart_set_ie(UART_CTRL_TX_IE);
    CHECK_EQ(intc_pending() & (IRQ_UART | IRQ_WTIMER), IRQ_UART | IRQ_WTIMER);
    CHECK_EQ(intc_active(), 0);              /* nothing enabled */
    CHECK_EQ(intc_claim(), -1);
    intc_set_enabled(IRQ_UART | IRQ_WTIMER);
    CHECK_EQ(intc_active(), IRQ_UART | IRQ_WTIMER);
    CHECK_EQ(intc_claim(), INTC_SRC_UART);   /* lowest active source first */
    arch_irq_enable(IRQ_MEI);
    arch_irq_global_enable();
    int ok = wait_flag(&mei_count, 2);
    timer_delay(200);
    irq_off();
    intc_set_enabled(0);
    CHECK(ok);
    CHECK_EQ(mei_count, 2);
    CHECK_EQ(mei_order[0], INTC_SRC_UART);
    CHECK_EQ(mei_order[1], INTC_SRC_WTIMER);
    /* a disabled source stays pending and does not interrupt */
    wtimer_start(10, 0);
    intc_set_enabled(IRQ_UART);
    uart_set_ie(0);
    arch_irq_enable(IRQ_MEI);
    arch_irq_global_enable();
    timer_delay(100);
    irq_off();
    CHECK_EQ(mei_count, 2);
    CHECK(intc_pending() & IRQ_WTIMER);
    CHECK_EQ(intc_active(), 0);
    wtimer_stop();
    intc_set_enabled(0);
    CHECK_EQ(intc_pending() & (IRQ_UART | IRQ_WTIMER | IRQ_PMU), 0);
    return TEST_PASS;
}
TEST(24, "irq_intc_priority_mask", CAP_INTC | CAP_WTIMER | CAP_UART, t_intc_priority);

static int t_wfi_wake(void)
{
    /* WFI with the source enabled but interrupts globally disabled must
     * resume execution without taking the interrupt */
    trap_set_irq_handler(IRQ_MTI, mti_handler);
    mti_count = 0;
    irq_off();
    arch_irq_enable(IRQ_MTI);
    uint64_t due = timer_now() + 400;
    timer_set_cmp(due);
    int n = 0;
    while (timer_now() < due && n < 1000) { pm_wfi(); n++; }
    uint64_t t = timer_now();
    timer_cancel();
    arch_irq_disable(IRQ_MTI);
    CHECK(t >= due);
    CHECK_EQ(mti_count, 0);
    if (suite_caps() & CAP_PMU) {
        CHECK_EQ(n, 1);                      /* one WFI covered the whole wait */
    }
    return TEST_PASS;
}
TEST(25, "irq_wfi_wake_masked", CAP_CLINT, t_wfi_wake);

static int t_irq_during_traffic(void)
{
    /* periodic timer interrupts while the main loop does memory traffic */
    static volatile uint32_t data[256];
    trap_set_irq_handler(IRQ_MTI, mti_handler);
    mti_count = 0;
    arch_irq_enable(IRQ_MTI);
    arch_irq_global_enable();
    uint32_t sum = 0, ref = 0;
    for (int round = 0; round < 8; round++) {
        timer_set_cmp(timer_now() + 40);
        for (uint32_t i = 0; i < 256; i++) data[i] = i * 2654435761u + (uint32_t)round;
        for (uint32_t i = 0; i < 256; i++) { sum += data[i]; ref += i * 2654435761u + (uint32_t)round; }
        uint64_t end = timer_now() + 2000;
        while (mti_count < (uint32_t)round + 1 && timer_now() < end) ;
    }
    irq_off();
    CHECK_EQ(sum, ref);
    CHECK_EQ(mti_count, 8);
    return TEST_PASS;
}
TEST(26, "irq_during_mem_traffic", CAP_CLINT, t_irq_during_traffic);
