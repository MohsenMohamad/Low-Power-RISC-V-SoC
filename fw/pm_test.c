/*
 * SoC power-management integration test (runs from the boot ROM).
 *
 * Self-checking: prints one line per step and finishes with "PASS" or
 * "FAIL <count>" on the UART. The testbench decodes the UART.
 *
 * Covers: RUN<->IDLE (wake timer, machine timer, software interrupt),
 * all six DVFS operating-point changes (with a CPU-vs-AON clock ratio check),
 * RUN<->SLEEP, RUN<->DEEP_SLEEP with RAM retention checks, wake from the
 * external wake pin, a refused power-down with a dirty D-cache, and a
 * sleep/wake stress loop mixing all of them.
 *
 * In-house core: WFI ends only on an interrupt pending and enabled in mie, so
 * main() enables MEIE/MTIE/MSIE (with mstatus.MIE = 0: no trap is taken).
 * pm_suspend() cleans the D-cache before WFI.
 */
#include <stdint.h>
#include "soc.h"

extern int pm_suspend(uint32_t mode);
extern volatile uint32_t pm_boot_status;
extern volatile uint32_t pm_test_skip_clean;

#define UART(o)   REG32(UART_BASE, o)
#define MTIMER(o) REG32(MTIMER_BASE, o)
#define INTC(o)   REG32(INTC_BASE, o)
#define PMU(o)    REG32(PMU_BASE, o)
#define WT(o)     REG32(WTIMER_BASE, o)

static uint32_t fails;
static uint32_t retained_buf[256];
static volatile uint32_t retained_marker;

/* ------------------------------------------------------------------ utils */
void *memset(void *d, int c, unsigned long n) {
  uint8_t *p = d;
  while (n--) *p++ = (uint8_t)c;
  return d;
}
void *memcpy(void *d, const void *s, unsigned long n) {
  uint8_t *p = d;
  const uint8_t *q = s;
  while (n--) *p++ = *q++;
  return d;
}

static void uart_putc(char c) {
  while (UART(UART_TXDATA) & 0x80000000u) {}
  UART(UART_TXDATA) = (uint32_t)(uint8_t)c;
}
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_puthex(uint32_t v) {
  for (int i = 7; i >= 0; i--) uart_putc("0123456789abcdef"[(v >> (4 * i)) & 0xF]);
}
static void uart_flush(void) {
  while (!(UART(UART_STATUS) & 0x2u)) {}
}

static void check(int cond, const char *what, uint32_t val) {
  if (!cond) {
    fails++;
    uart_puts("  ERR ");
    uart_puts(what);
    uart_puts(" 0x");
    uart_puthex(val);
    uart_putc('\n');
  }
}

static inline uint32_t rdcycle(void) {
  uint32_t c;
  __asm__ volatile("rdcycle %0" : "=r"(c));
  return c;
}

/* Clean the D-cache now, so the clean inside pm_suspend() finds (almost)
 * nothing dirty and the low-power entry is quick compared with the wake-up
 * delays below. Each dirty line costs four single-beat AXI writes across the
 * CPU->AON bridge. Returns the write-back error bit. */
static uint32_t dcache_clean(void) {
  uint32_t v;
  __asm__ volatile("csrwi 0x7C0, 4\n\tcsrr %0, 0x7C0" : "=r"(v)::"memory");
  return v & MCACHECTL_WBERR;
}

/* Wake-up delays in clk_aon cycles. They must exceed the low-power entry time
 * at the slowest operating point (OP0) including the D-cache scan in
 * pm_suspend(). After a SLEEP resume both caches are cold and every line
 * refill crosses the CPU->AON bridge as four single-beat reads; at OP0 the
 * stress loop measured ~5100 clk_aon cycles from wt_arm() to WFI. */
#define WAKE_IDLE   4000u
#define WAKE_OFF    12000u
#define WAKE_STRESS 12000u

static void wt_arm(uint32_t ticks) {
  WT(WT_CTRL) = 0;
  WT(WT_STATUS) = 1;
  WT(WT_LOAD) = ticks;
  WT(WT_CTRL) = 1;
}
static void wt_stop(void) {
  WT(WT_CTRL) = 0;
  WT(WT_STATUS) = 1;
}

static void mtimecmp_set(uint32_t lo, uint32_t hi) {
  MTIMER(MTIMECMP_HI) = 0xFFFFFFFFu;
  MTIMER(MTIMECMP_LO) = lo;
  MTIMER(MTIMECMP_HI) = hi;
}

static uint32_t checksum(void) {
  uint32_t s = 0x12345678u;
  for (unsigned i = 0; i < sizeof(retained_buf) / 4; i++) s = (s << 5 | s >> 27) ^ retained_buf[i];
  return s;
}

/* CPU cycles per 64 AON cycles, measured with rdcycle vs mtime. */
static uint32_t clk_ratio(void) {
  uint32_t t0 = MTIMER(MTIME_LO);
  uint32_t c0 = rdcycle();
  while ((uint32_t)(MTIMER(MTIME_LO) - t0) < 256u) {}
  uint32_t c1 = rdcycle();
  uint32_t t1 = MTIMER(MTIME_LO);
  return ((c1 - c0) * 64u) / (t1 - t0);
}

/* ------------------------------------------------------------------ steps */
static void step(const char *name) {
  uart_puts("[step] ");
  uart_puts(name);
  uart_putc('\n');
}

static void test_idle_wake_timer(void) {
  step("idle/wake-timer");
  INTC(INTC_ENABLE) = IRQ_WTIMER;
  check(dcache_clean() == 0, "clean", 0);
  wt_arm(WAKE_IDLE);
  int r = pm_suspend(PMU_MODE_IDLE);
  check(r == 0, "idle returned", (uint32_t)r);
  check(PMU(PMU_WAKE_CAUSE) & WAKE_MEIP, "wake cause", PMU(PMU_WAKE_CAUSE));
  check(INTC(INTC_PENDING) & IRQ_WTIMER, "wt pending", INTC(INTC_PENDING));
  wt_stop();
  INTC(INTC_ENABLE) = 0;
}

static void test_idle_mtimer(void) {
  step("idle/mtimer");
  check(dcache_clean() == 0, "clean", 0);
  uint32_t now = MTIMER(MTIME_LO);
  mtimecmp_set(now + WAKE_IDLE, MTIMER(MTIME_HI) + ((now + WAKE_IDLE) < now));
  int r = pm_suspend(PMU_MODE_IDLE);
  check(r == 0, "idle returned", (uint32_t)r);
  check(PMU(PMU_WAKE_CAUSE) & WAKE_MTIP, "wake cause", PMU(PMU_WAKE_CAUSE));
  mtimecmp_set(0xFFFFFFFFu, 0xFFFFFFFFu);
}

static void test_idle_msip_pending(void) {
  step("idle/msip-already-pending");
  MTIMER(MSIP) = 1;
  int r = pm_suspend(PMU_MODE_IDLE);
  check(r == 0, "idle returned", (uint32_t)r);
  MTIMER(MSIP) = 0;
}

static uint32_t ratio_at[3];

static void dvfs_to(uint32_t op) {
  PMU(PMU_DVFS) = op;
  PMU(PMU_IRQ_EN) = 1;
  INTC(INTC_ENABLE) = IRQ_PMU;
  int r = pm_suspend(PMU_MODE_IDLE);
  uint32_t st = PMU(PMU_STATUS);
  check(r == 0, "dvfs idle returned", (uint32_t)r);
  check(PMU_ST_CUR_OP(st) == op, "dvfs op", st);
  check(st & PMU_ST_DVFS_DONE, "dvfs done", st);
  check(!(st & PMU_ST_DVFS_PEND), "dvfs pending", st);
  check(PMU(PMU_VSEL) == op, "vsel", PMU(PMU_VSEL));
  PMU(PMU_STATUS) = PMU_ST_DVFS_DONE;
  INTC(INTC_ENABLE) = 0;
  PMU(PMU_IRQ_EN) = 0;
  ratio_at[op] = clk_ratio();
  uart_puts("  op ");
  uart_putc((char)('0' + op));
  uart_puts(" cpu/aon*64 = 0x");
  uart_puthex(ratio_at[op]);
  uart_putc('\n');
}

static void test_dvfs(void) {
  step("dvfs/all-transitions");
  /* from OP2: 2->1, 1->0, 0->2, 2->0, 0->1, 1->2 covers all six ordered pairs */
  static const uint8_t seq[6] = {1, 0, 2, 0, 1, 2};
  for (int i = 0; i < 6; i++) dvfs_to(seq[i]);
  check(ratio_at[0] < ratio_at[1] && ratio_at[1] < ratio_at[2], "freq order", ratio_at[0]);
}

static void test_power_off(uint32_t mode, const char *name, int use_ext_pin) {
  step(name);
  uint32_t cnt0 = PMU(PMU_SLEEP_CNT);
  for (unsigned i = 0; i < sizeof(retained_buf) / 4; i++) retained_buf[i] = i * 0x9E3779B9u + cnt0;
  uint32_t sum = checksum();
  volatile uint32_t on_stack = 0xA5A55A5Au ^ cnt0;
  retained_marker = 0xCAFEBABEu;

  uart_flush();
  check(dcache_clean() == 0, "clean", 0);
  if (use_ext_pin) {
    INTC(INTC_ENABLE) = IRQ_EXT_WAKE;
    wt_stop();
  } else {
    INTC(INTC_ENABLE) = IRQ_WTIMER;
    wt_arm(WAKE_OFF);
  }
  int r = pm_suspend(mode);
  uint32_t bs = pm_boot_status;

  check(r == 1, "resumed", (uint32_t)r);
  check(bs & PMU_ST_RESUME, "boot status resume", bs);
  check(((bs & PMU_ST_RESUME_DEEP) != 0) == (mode == PMU_MODE_DEEP), "boot status deep", bs);
  check(PMU(PMU_SLEEP_CNT) == cnt0 + 1, "sleep count", PMU(PMU_SLEEP_CNT));
  check(retained_marker == 0xCAFEBABEu, "marker", retained_marker);
  check(on_stack == (0xA5A55A5Au ^ cnt0), "stack", on_stack);
  check(checksum() == sum, "ram checksum", checksum());
  check(PMU(PMU_WAKE_CAUSE) & WAKE_MEIP, "wake cause", PMU(PMU_WAKE_CAUSE));
  check(!(PMU(PMU_STATUS) & PMU_ST_RESUME), "resume flag cleared", PMU(PMU_STATUS));
  wt_stop();
  INTC(INTC_ENABLE) = 0;
}

/* The PMU must refuse SLEEP while the D-cache holds dirty lines: the CPU
 * stays powered (clock gated), STATUS.ERR_DIRTY is set, SLEEP_CNT does not
 * change and the dirty data is intact after the wake-up. */
static void test_dirty_refusal(void) {
  step("sleep/dirty-dcache-refused");
  uint32_t cnt0 = PMU(PMU_SLEEP_CNT);
  PMU(PMU_STATUS) = PMU_ST_ERR_DIRTY;
  for (unsigned i = 0; i < 16; i++) retained_buf[i] = 0x51EE0000u + i;
  INTC(INTC_ENABLE) = IRQ_WTIMER;
  wt_arm(WAKE_OFF);
  pm_test_skip_clean = 1;
  int r = pm_suspend(PMU_MODE_SLEEP);
  pm_test_skip_clean = 0;
  uint32_t st = PMU(PMU_STATUS);
  check(r == 0, "refused sleep returned", (uint32_t)r);
  check(st & PMU_ST_ERR_DIRTY, "err_dirty", st);
  check(!(st & PMU_ST_RESUME), "no resume", st);
  check(PMU(PMU_SLEEP_CNT) == cnt0, "sleep count unchanged", PMU(PMU_SLEEP_CNT));
  for (unsigned i = 0; i < 16; i++)
    check(retained_buf[i] == 0x51EE0000u + i, "dirty data", retained_buf[i]);
  PMU(PMU_STATUS) = PMU_ST_ERR_DIRTY;
  wt_stop();
  INTC(INTC_ENABLE) = 0;
}

static void test_stress(int iterations) {
  step("stress/sleep-wake-loop");
  static const uint8_t op_seq[5] = {0, 2, 1, 1, 2};
  for (int i = 0; i < iterations; i++) {
    uint32_t mode = (uint32_t)(i % 3);
    if (mode == PMU_MODE_IDLE) {
      PMU(PMU_DVFS) = op_seq[i % 5];
    }
    uint32_t cnt0 = PMU(PMU_SLEEP_CNT);
    retained_marker = 0x1000u + (uint32_t)i;
    INTC(INTC_ENABLE) = IRQ_WTIMER;
    check(dcache_clean() == 0, "clean", (uint32_t)i);
    wt_arm(WAKE_STRESS + 37u * (uint32_t)i);
    int r = pm_suspend(mode);
    check(r == (mode != PMU_MODE_IDLE), "stress return", (uint32_t)i);
    check(retained_marker == 0x1000u + (uint32_t)i, "stress marker", retained_marker);
    check(PMU(PMU_SLEEP_CNT) == cnt0 + (mode != PMU_MODE_IDLE), "stress count", (uint32_t)i);
    if (mode == PMU_MODE_IDLE)
      check(PMU_ST_CUR_OP(PMU(PMU_STATUS)) == op_seq[i % 5], "stress op", PMU(PMU_STATUS));
    PMU(PMU_STATUS) = PMU_ST_DVFS_DONE;
    wt_stop();
  }
  INTC(INTC_ENABLE) = 0;
}

int main(void) {
  uart_puts("\nlp-soc pm_test\n");
  /* wake sources: interrupt controller, machine timer, software interrupt */
  __asm__ volatile("csrw mie, %0" ::"r"(MIE_MEIE | MIE_MTIE | MIE_MSIE));
  check(PMU_ST_CUR_OP(PMU(PMU_STATUS)) == 2, "reset op", PMU(PMU_STATUS));
  check(PMU(PMU_SLEEP_CNT) == 0, "reset sleep count", PMU(PMU_SLEEP_CNT));

  test_idle_wake_timer();
  test_idle_mtimer();
  test_idle_msip_pending();
  test_dvfs();
  test_power_off(PMU_MODE_SLEEP, "sleep/wake-timer", 0);
  test_power_off(PMU_MODE_DEEP, "deep-sleep/wake-timer", 0);
  test_power_off(PMU_MODE_SLEEP, "sleep/ext-wake-pin", 1);
  test_power_off(PMU_MODE_DEEP, "deep-sleep/ext-wake-pin", 1);
  test_dirty_refusal();
  test_stress(12);

  if (fails == 0) {
    uart_puts("PASS\n");
  } else {
    uart_puts("FAIL 0x");
    uart_puthex(fails);
    uart_putc('\n');
  }
  uart_flush();
  for (;;) {}
}
