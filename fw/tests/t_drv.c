/* Validation: driver-level register checks against doc/SOC_REGMAP.md, bus
 * error and register access rules, and the boot ROM handoff (doc/BOOT_ABI.md). */
#include "test.h"
#include "arch.h"
#include "trap.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"
#include "pm.h"

static int t_uart(void)
{
    uart_flush();
    CHECK(uart_status() & UART_ST_TX_IDLE);
    CHECK(!(uart_status() & UART_ST_TX_FULL));
    CHECK(!(uart_status() & UART_ST_RX_VALID));
    CHECK(!(REG32(UART_BASE + UART_TXDATA) & UART_TXDATA_FULL));
    uint32_t div = uart_get_div();
    CHECK_EQ(div, 8);                        /* reset value, testbench decoder */
    uart_set_div(div * 2);                   /* nothing is sent meanwhile */
    CHECK_EQ(uart_get_div(), div * 2);
    uart_set_div(div);
    CHECK_EQ(uart_get_div(), div);
    uart_set_ie(UART_CTRL_RX_IE | UART_CTRL_TX_IE);
    CHECK_EQ(REG32(UART_BASE + UART_CTRL), UART_CTRL_RX_IE | UART_CTRL_TX_IE | div);
    /* TX idle interrupt request is visible at the intc (source 0) */
    CHECK(intc_pending() & IRQ_UART);
    uart_set_ie(UART_CTRL_RX_IE);            /* RX empty: no request */
    CHECK(!(intc_pending() & IRQ_UART));
    uart_set_ie(0);
    CHECK_EQ(REG32(UART_BASE + UART_CTRL), div);
    CHECK(REG32(UART_BASE + UART_RXDATA) & UART_RXDATA_EMPTY);
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
    timer_set_msip(1);
    CHECK_EQ(timer_get_msip(), 1);
    timer_set_msip(0);
    CHECK_EQ(timer_get_msip(), 0);
#if PLATFORM_HAS_SOC
    /* mtime increments once per clk_aon cycle (no prescaler) and is
     * writable; time CSR follows it */
    uint32_t hi = REG32(MTIMER_BASE + MTIME_HI);
    REG32(MTIMER_BASE + MTIME_HI) = hi + 1;
    CHECK(REG32(MTIMER_BASE + MTIME_HI) >= hi + 1);
    REG32(MTIMER_BASE + MTIME_HI) = hi;
    /* Warm the I-cache first and measure over the ticks that actually
     * elapsed between the two samples: a cold miss between reading mtime and
     * mcycle counted ticks without cycles (found on the in-house SoC). */
    uint64_t t0, c0, t1, c1;
    for (int pass = 0; pass < 2; pass++) {
        t0 = timer_now();
        c0 = arch_cycles();
        while ((t1 = timer_now()) < t0 + 1000) ;
        c1 = arch_cycles();
    }
    uint64_t exp = (t1 - t0) * AON_PERIOD_PS / OP2_PERIOD_PS;      /* at OP2 */
    printf_("    %u ticks: %u cpu cycles (expected about %u)\n", (unsigned)(t1 - t0),
            (unsigned)(c1 - c0), (unsigned)exp);
    CHECK(c1 - c0 > exp * 9 / 10 && c1 - c0 < exp * 11 / 10);
#endif
    return TEST_PASS;
}
TEST(71, "drv_timer", CAP_CLINT, t_timer);

static int t_intc(void)
{
    intc_set_enabled(0xA5);
    CHECK_EQ(intc_enabled(), 0xA5);
    intc_set_enabled(0);
    CHECK_EQ(intc_enabled(), 0);
    CHECK_EQ(intc_pending() & 0xF0u, 0);     /* reserved sources read 0 */
    wtimer_start(5, 0);
    timer_delay(20);
    CHECK_EQ(intc_pending() & IRQ_WTIMER, IRQ_WTIMER);
    CHECK_EQ(intc_active(), 0);
    CHECK_EQ(intc_claim(), -1);              /* nothing enabled */
    intc_enable(INTC_SRC_WTIMER);
    CHECK_EQ(intc_active(), IRQ_WTIMER);
    CHECK_EQ(intc_claim(), INTC_SRC_WTIMER);
    wtimer_ack();                            /* cleared at the origin */
    CHECK_EQ(intc_pending() & IRQ_WTIMER, 0);
    CHECK_EQ(intc_claim(), -1);
    intc_set_enabled(0);
    /* byte write on lane 0 updates ENABLE */
    *(volatile uint8_t *)(INTC_BASE + INTC_ENABLE) = 0x0C;
    CHECK_EQ(intc_enabled(), 0x0C);
    intc_set_enabled(0);
    return TEST_PASS;
}
TEST(72, "drv_intc", CAP_INTC | CAP_WTIMER, t_intc);

static int t_pmu(void)
{
    uint32_t st = pmu_status();
    CHECK_EQ(PMU_ST_STATE(st), PMU_STATE_RUN);
    CHECK_EQ(PMU_ST_CUR_OP(st), PMU_RESET_OP);
    CHECK(!(st & PMU_ST_DVFS_PEND));
    CHECK_EQ(pmu_read(PMU_CTRL), PMU_CTRL_LP_EN | PMU_MODE_IDLE);
    CHECK_EQ(pmu_read(PMU_DVFS), PMU_RESET_OP);
    CHECK_EQ(pmu_read(PMU_VSEL), PMU_RESET_OP);
    CHECK_EQ(pmu_read(PMU_IRQ_EN), 0);
    CHECK_EQ(pmu_wake_mask(), WAKE_ALL);     /* suite baseline = reset value */
    pmu_set_wake_mask(WAKE_MTIP);
    CHECK_EQ(pmu_wake_mask(), WAKE_MTIP);
    pmu_write(PMU_WAKE_MASK, 0xFFFFFFFFu);
    CHECK_EQ(pmu_wake_mask(), WAKE_ALL);     /* bits 31:3 read 0 */
    uint32_t ic = pmu_idle_count();
    timer_delay(20);
    CHECK_EQ(pmu_idle_count(), ic);          /* only counts IDLE entries */
    pmu_write(PMU_IRQ_EN, 1);
    CHECK_EQ(pmu_read(PMU_IRQ_EN), 1);
    pmu_write(PMU_IRQ_EN, 0);
    /* scratch registers are plain RW */
    uint32_t s0 = pmu_read(PMU_SCRATCH0);
    pmu_write(PMU_SCRATCH0, 0xA5A55A5Au);
    CHECK_EQ(pmu_read(PMU_SCRATCH0), 0xA5A55A5Au);
    pmu_write(PMU_SCRATCH0, s0);
    /* MODE 3 reads back as IDLE; DVFS writes of 3 are ignored */
    pmu_write(PMU_CTRL, 3u | PMU_CTRL_LP_EN);
    CHECK_EQ(pmu_read(PMU_CTRL), PMU_CTRL_LP_EN | PMU_MODE_IDLE);
    pmu_write(PMU_DVFS, 3);
    CHECK_EQ(pmu_read(PMU_DVFS), PMU_RESET_OP);
    pmu_set_mode(PMU_MODE_IDLE);
    return TEST_PASS;
}
TEST(73, "drv_pmu_regs", CAP_PMU, t_pmu);

static int t_wtimer(void)
{
    wtimer_stop();
    CHECK(!wtimer_expired());
    wtimer_start(1000, 0);
    uint32_t c0 = wtimer_count();
    timer_delay(50);
    uint32_t c1 = wtimer_count();
    CHECK(c0 <= 1000 && c1 < c0);            /* counts down on clk_aon */
    CHECK(!wtimer_expired());
    timer_delay(1100);
    CHECK(wtimer_expired());
    CHECK_EQ(REG32(WTIMER_BASE + WT_CTRL) & WT_CTRL_EN, 0);     /* one-shot */
    wtimer_ack();
    CHECK(!wtimer_expired());
    /* periodic: reloads and expires again */
    wtimer_start(100, 1);
    timer_delay(150);
    CHECK(wtimer_expired());
    wtimer_ack();
    timer_delay(150);
    CHECK(wtimer_expired());
    CHECK(REG32(WTIMER_BASE + WT_CTRL) & WT_CTRL_EN);
    wtimer_stop();
    CHECK(!wtimer_expired());
    return TEST_PASS;
}
TEST(75, "drv_wake_timer", CAP_WTIMER | CAP_CLINT, t_wtimer);

/* ---- bus errors and register access rules (doc/SPEC.md, doc/SOC_REGMAP.md;
 * audit W18, W19): SLVERR -> precise load / store access fault, the register
 * keeps its value. */
static volatile uint32_t f_count, f_cause, f_tval;

static void fault_rec(trap_frame_t *f)
{
    f_count = f_count + 1;
    f_cause = f->cause;
    f_tval  = f->tval;
    f->epc += 4;
}

static int ld_faults(uint32_t addr)
{
    uint32_t n = f_count;
    (void)REG32(addr);
    return f_count == n + 1 && f_cause == EXC_LOAD_FAULT && f_tval == addr;
}

static int sw_faults(uint32_t addr, uint32_t v)
{
    uint32_t n = f_count;
    REG32(addr) = v;
    return f_count == n + 1 && f_cause == EXC_STORE_FAULT && f_tval == addr;
}

static int sh_faults(uint32_t addr, uint16_t v)
{
    uint32_t n = f_count;
    *(volatile uint16_t *)(uintptr_t)addr = v;
    return f_count == n + 1 && f_cause == EXC_STORE_FAULT;
}

static int t_bus_errors(void)
{
    f_count = 0;
    trap_set_exc_handler(fault_rec);
    /* unmapped regions */
    CHECK(ld_faults(0x60000000u));
    CHECK(sw_faults(0x60000000u, 1));
    CHECK(ld_faults(DEBUG_BASE));                         /* debug blocks: not implemented */
    CHECK(ld_faults(0x20005000u));                        /* gap after the wake timer */
    CHECK(ld_faults(RAM_ALIAS_BASE + SOC_RAM_SIZE));       /* just past the alias */
    CHECK(sw_faults(ROM_BASE + 0x100, 0));                /* ROM write */
    /* unmapped offsets inside a peripheral */
    CHECK(ld_faults(UART_BASE + 0x10));
    CHECK(ld_faults(PMU_BASE + 0x40));
    CHECK(ld_faults(INTC_BASE + 0x0C));
    CHECK(ld_faults(MTIMER_BASE + 0x14));
    /* writes to read-only registers keep the value */
    uint32_t cnt = pmu_sleep_count();
    CHECK(sw_faults(PMU_BASE + PMU_SLEEP_CNT, cnt + 5));
    CHECK_EQ(pmu_sleep_count(), cnt);
    CHECK(sw_faults(PMU_BASE + PMU_WAKE_CAUSE, 7));
    CHECK(sw_faults(PMU_BASE + PMU_VSEL, 0));
    uint32_t ic = pmu_idle_count();
    CHECK(sw_faults(PMU_BASE + PMU_IDLE_CNT, 0));
    CHECK_EQ(pmu_idle_count(), ic);
    CHECK_EQ(pmu_read(PMU_VSEL), pmu_cur_op());
    CHECK(sw_faults(INTC_BASE + INTC_PENDING, 0xFF));
    CHECK(sw_faults(INTC_BASE + INTC_ACTIVE, 0xFF));
    CHECK(sw_faults(UART_BASE + UART_RXDATA, 0x41));
    CHECK(sw_faults(WTIMER_BASE + WT_COUNT, 5));
    /* partial writes to full-word registers keep the value */
    uint32_t s0 = pmu_read(PMU_SCRATCH0);
    CHECK(sh_faults(PMU_BASE + PMU_SCRATCH0, 0x1234));
    CHECK_EQ(pmu_read(PMU_SCRATCH0), s0);
    uint32_t ld = REG32(WTIMER_BASE + WT_LOAD);
    CHECK(sh_faults(WTIMER_BASE + WT_LOAD, 0x55));
    CHECK_EQ(REG32(WTIMER_BASE + WT_LOAD), ld);
    trap_set_exc_handler(0);
    printf_("    %u access faults, all precise with the faulting address\n", (unsigned)f_count);
    return TEST_PASS;
}
TEST(76, "bus_errors_access_rules", CAP_PMU | CAP_INTC | CAP_UART | CAP_WTIMER, t_bus_errors);

#if PLATFORM_HAS_SOC
extern const image_hdr_t image_header;

static int t_boot_info(void)
{
    volatile handoff_t *h = HANDOFF;
    CHECK_EQ(h->rom_version, ROM_VERSION);
    CHECK(h->boot_status == BOOT_COLD || h->boot_status == BOOT_RESUMED ||
          h->boot_status == BOOT_RESUME_BADCTX);
    CHECK(h->cold_boots >= 1);
    CHECK(h->rst_cause >= RST_POR && h->rst_cause <= RST_DEEP);
    const image_hdr_t *img = &image_header;
    CHECK_EQ((uint32_t)(uintptr_t)img, APP_BASE);
    CHECK_EQ(img->magic, IMAGE_MAGIC);
    CHECK_EQ(img->version, IMAGE_VERSION);
    CHECK_EQ(img->load_addr, APP_BASE);
    CHECK_EQ(img->entry & 3u, 0);
    CHECK(img->entry > APP_BASE && img->entry < APP_BASE + img->size);
    CHECK_EQ(crc32((const uint8_t *)img + sizeof(*img), img->size - sizeof(*img)), img->crc);
    /* the ROM consumed the resume state */
    CHECK_EQ(pmu_read(PMU_SCRATCH1), 0);
    CHECK(!(pmu_status() & PMU_ST_RESUME));
    return TEST_PASS;
}
TEST(74, "boot_rom_handoff", CAP_BOOTROM, t_boot_info);
#endif
