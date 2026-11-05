/* Validation: driver-level register checks and boot ROM handoff. */
#include "test.h"
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"

static int t_uart(void)
{
    uart_flush();
    CHECK(uart_status() & UART_ST_TX_IDLE);
    CHECK(!(uart_status() & UART_ST_TX_FULL));
    uint32_t div = uart_get_div();
    CHECK(div >= 4);
    uart_set_div(div * 2);                   /* nothing is sent meanwhile */
    CHECK_EQ(uart_get_div(), div * 2);
    uart_set_div(div);
    CHECK_EQ(uart_get_div(), div);
    REG32(UART_BASE + UART_IE) = UART_IE_RX | UART_IE_TX_IDLE;
    CHECK_EQ(REG32(UART_BASE + UART_IE), UART_IE_RX | UART_IE_TX_IDLE);
    /* TX idle interrupt request is visible at the intc */
    CHECK(REG32(INTC_BASE + INTC_RAW) & (1u << INTC_SRC_UART));
    uart_set_ie(0);
    timer_delay(4);
    CHECK(!(REG32(INTC_BASE + INTC_RAW) & (1u << INTC_SRC_UART)));
    CHECK_EQ(uart_getc(), -1);               /* nothing received */
    return TEST_PASS;
}
TEST(70, "drv_uart", CAP_UART | CAP_INTC, t_uart);

static int t_timer(void)
{
    uint64_t a = timer_now();
    timer_delay(100);
    uint64_t b = timer_now();
    CHECK(b >= a + 100 && b < a + 1000);
    timer_set_cmp(0x123456789ABCull);
    CHECK(timer_get_cmp() == 0x123456789ABCull);
    timer_cancel();
    CHECK(timer_get_cmp() == ~0ull);
#if PLATFORM_HAS_SOC
    /* prescaler: mtime advances once every PRESCALE+1 clk_aon cycles */
    uint64_t c0 = arch_cycles(), t0 = timer_now();
    while (timer_now() < t0 + 400) ;
    uint64_t r1 = arch_cycles() - c0;
    REG32(CLINT_BASE + CLINT_PRESCALE) = 3;
    c0 = arch_cycles(); t0 = timer_now();
    while (timer_now() < t0 + 100) ;
    uint64_t r4 = arch_cycles() - c0;
    REG32(CLINT_BASE + CLINT_PRESCALE) = 0;
    printf_("    400 ticks: %u cycles, 100 ticks at prescale 4: %u cycles\n", (unsigned)r1, (unsigned)r4);
    CHECK(r4 > r1 * 9 / 10 && r4 < r1 * 11 / 10);
#endif
    return TEST_PASS;
}
TEST(71, "drv_timer", CAP_CLINT, t_timer);

static int t_intc(void)
{
    intc_set_enabled(0xA5);
    CHECK_EQ(intc_enabled(), 0xA5);
    intc_set_enabled(0);
    intc_soft_set(0x90);
    CHECK_EQ(intc_pending() & 0x90u, 0x90u);
    CHECK_EQ(REG32(INTC_BASE + INTC_RAW) & 0x90u, 0);   /* RAW excludes soft bits */
    CHECK_EQ(intc_claim(), -1);                         /* nothing enabled */
    intc_enable(7);
    CHECK_EQ(intc_claim(), 7);
    intc_enable(4);
    CHECK_EQ(intc_claim(), 4);
    intc_soft_clr(0x90);
    CHECK_EQ(intc_claim(), -1);
    intc_set_enabled(0);
    return TEST_PASS;
}
TEST(72, "drv_intc", CAP_INTC, t_intc);

static int t_pmu(void)
{
    CHECK_EQ(pmu_read(PMU_ID), PMU_ID_VALUE);
    uint32_t rc = pmu_rst_cause();
    CHECK(rc >= PMU_RC_POR && rc <= PMU_RC_SWRST);
    pmu_set_wake(7);
    CHECK_EQ(pmu_read(PMU_WAKE_EN), 7);
    pmu_set_wake(0);
    CHECK_EQ(pmu_read(PMU_WAKE_EN), 0);
    pmu_write(PMU_EVENT_IE, 3);
    CHECK_EQ(pmu_read(PMU_EVENT_IE), 3);
    pmu_write(PMU_EVENT_IE, 0);
    CHECK_EQ(pmu_read(PMU_CTRL), 0);
    CHECK(pmu_read(PMU_STATUS) & (1u << 9));            /* PD_CPU power good */
    return TEST_PASS;
}
TEST(73, "drv_pmu_regs", CAP_PMU, t_pmu);

#if PLATFORM_HAS_SOC
extern const image_hdr_t image_header;
#ifdef ARCH_PICORV32
extern void trap_entry(void);
#endif

static int t_boot_info(void)
{
    volatile handoff_t *h = HANDOFF;
    CHECK_EQ(h->rom_version, 0x00010000u);
    CHECK(h->boot_status == BOOT_COLD || h->boot_status == BOOT_RESUMED ||
          h->boot_status == BOOT_RESUME_BADCTX);
    CHECK(h->cold_boots >= 1);
    CHECK_EQ(h->rst_cause, pmu_rst_cause());
    const image_hdr_t *img = &image_header;
    CHECK_EQ((uint32_t)(uintptr_t)img, APP_BASE);
    CHECK_EQ(img->magic, IMAGE_MAGIC);
    CHECK_EQ(crc32((const uint8_t *)img + sizeof(*img), img->size - sizeof(*img)), img->crc);
#ifdef ARCH_PICORV32
    CHECK_EQ(h->soft_mtvec, (uint32_t)(uintptr_t)trap_entry);
#endif
    return TEST_PASS;
}
TEST(74, "boot_rom_handoff", CAP_BOOTROM, t_boot_info);
#endif
