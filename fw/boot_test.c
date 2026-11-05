/*
 * Integrated-SoC boot test (stage 1). Runs from the boot ROM on the in-house
 * RV32IM core with I-/D-cache and checks, self-checking over the UART:
 *
 *   boot      cold boot from ROM at the SPEC reset vector 0x0000_0000
 *   ramexec   code executed from RAM (copied by crt0, fence.i), I-cache on RAM
 *   mtime     time CSR (mtime exported through the snapshot CDC) tracks the
 *             machine-timer register
 *   timerirq  machine-timer interrupt taken through mtvec (MTIE, mstatus.MIE)
 *   alias     uncached RAM alias 0x3000_0000: bypasses the write-back D-cache
 *   unmapped  an unmapped address returns SLVERR (load access fault)
 *   dirtyref  SLEEP refused while the D-cache holds dirty data (ERR_DIRTY)
 *   sleep     full SLEEP / resume with dirty data in the D-cache: the data is
 *             written back by pm_suspend, the CPU is powered off, the boot ROM
 *             verifies the context CRC and resumes
 *   crcfail   a resume context with a bad CRC is rejected and the ROM
 *             cold-boots; progress across that reboot is kept in RAM through
 *             the uncached alias
 *
 * Prints "PASS" or "FAIL <n>"; every check prints "  ERR ..." on failure.
 */
#include <stdint.h>
#include "soc.h"

extern int pm_suspend(uint32_t mode);
extern volatile uint32_t pm_boot_status;
extern volatile uint32_t pm_boot_reason;
extern volatile uint32_t pm_test_skip_clean;
extern volatile uint32_t pm_test_crc_flip;
extern char _persist[];

#define UART(o)   REG32(UART_BASE, o)
#define MTIMER(o) REG32(MTIMER_BASE, o)
#define INTC(o)   REG32(INTC_BASE, o)
#define PMU(o)    REG32(PMU_BASE, o)
#define WT(o)     REG32(WTIMER_BASE, o)

/* State kept across the deliberate cold reboot (end of RAM, uncached). */
struct persist {
  uint32_t magic;
  uint32_t phase;
  uint32_t fails;
  uint32_t sleep_cnt;
};
#define PERSIST_MAGIC 0xB007CAFEu
#define PERSIST ((volatile struct persist *)RAM_ALIAS(_persist))

static uint32_t fails;

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
static void uart_flush(void) { while (!(UART(UART_STATUS) & 0x2u)) {} }

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
static void step(const char *name) {
  uart_puts("[step] ");
  uart_puts(name);
  uart_putc('\n');
}

static inline uint32_t csr_mcachectl(uint32_t cmd) {
  uint32_t v;
  __asm__ volatile("csrw 0x7C0, %1\n\tcsrr %0, 0x7C0" : "=r"(v) : "r"(cmd) : "memory");
  return v;
}
static inline uint32_t rdtime(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, time" : "=r"(v));
  return v;
}

/* ------------------------------------------------------------- trap handler */
static volatile uint32_t irq_count, ext_irq_count, last_mcause, exc_count, exc_mtval;

void __attribute__((interrupt("machine"), aligned(4))) trap_handler(void) {
  uint32_t cause, epc;
  __asm__ volatile("csrr %0, mcause" : "=r"(cause));
  if (cause == 0x8000000Bu) {
    /* unexpected external interrupt: mask it at the controller (no storm)
     * and count it so the test fails visibly */
    last_mcause = cause;
    ext_irq_count++;
    INTC(INTC_ENABLE) = 0;
  } else if (cause & 0x80000000u) {
    last_mcause = cause;
    irq_count++;
    MTIMER(MTIMECMP_HI) = 0xFFFFFFFFu;   /* acknowledge: mtip falls */
    MTIMER(MTIMECMP_LO) = 0xFFFFFFFFu;
  } else {
    last_mcause = cause;
    exc_count++;
    __asm__ volatile("csrr %0, mtval" : "=r"(exc_mtval));
    __asm__ volatile("csrr %0, mepc" : "=r"(epc));
    __asm__ volatile("csrw mepc, %0" ::"r"(epc + 4));   /* skip the faulting insn */
  }
}

/* ------------------------------------------------------------- RAM code */
__attribute__((section(".ramtext"), noinline)) uint32_t ram_func(uint32_t x) {
  uint32_t pc;
  __asm__ volatile("auipc %0, 0" : "=r"(pc));
  /* returns the PC it ran at, mixed with a computation on x */
  return (x * 2654435761u) ^ pc;
}

static void test_ramexec(void) {
  step("ramexec");
  uint32_t f = (uint32_t)(uintptr_t)&ram_func;
  check((f & 0xFFFE0000u) == RAM_BASE, "ram_func address", f);
  uint32_t r = ram_func(12345u);
  uint32_t pc = r ^ (12345u * 2654435761u);
  check((pc & 0xFFFE0000u) == RAM_BASE, "pc in RAM", pc);
  check(ram_func(1u) == (2654435761u ^ pc), "ram_func result", ram_func(1u));
}

static void test_mtime(void) {
  step("mtime");
  for (int i = 0; i < 4; i++) {
    uint32_t m0 = MTIMER(MTIME_LO);
    uint32_t t = rdtime();
    uint32_t m1 = MTIMER(MTIME_LO);
    /* rdtime is a coherent snapshot that lags the counter by a few clk_aon
     * cycles (doc/CPU_SOC_INTERFACE.md): m0 - 16 <= t <= m1 */
    check((uint32_t)(t - (m0 - 16u)) <= (uint32_t)(m1 - (m0 - 16u)), "rdtime window", t);
  }
  uint32_t a = rdtime(), b;
  for (volatile int i = 0; i < 50; i++) {}
  b = rdtime();
  check(b > a, "rdtime advances", b - a);
}

static void test_timer_irq(void) {
  step("timerirq");
  __asm__ volatile("csrw mtvec, %0" ::"r"((uintptr_t)&trap_handler));
  irq_count = 0;
  uint32_t now = MTIMER(MTIME_LO);
  MTIMER(MTIMECMP_HI) = 0xFFFFFFFFu;
  MTIMER(MTIMECMP_LO) = now + 300u;
  MTIMER(MTIMECMP_HI) = MTIMER(MTIME_HI) + ((now + 300u) < now);
  __asm__ volatile("csrs mie, %0" ::"r"(MIE_MTIE));
  __asm__ volatile("csrs mstatus, %0" ::"r"(MSTATUS_MIE));
  uint32_t spins = 0;
  while (irq_count == 0 && spins < 200000u) spins++;
  __asm__ volatile("csrc mstatus, %0" ::"r"(MSTATUS_MIE));
  check(irq_count == 1, "timer irq count", irq_count);
  check(ext_irq_count == 0, "unexpected external irq", ext_irq_count);
  check(last_mcause == 0x80000007u, "mcause", last_mcause);
  check(MTIMER(MTIME_LO) - now >= 300u, "irq not early", MTIMER(MTIME_LO) - now);
}

static volatile uint32_t alias_buf[8] __attribute__((aligned(16)));

static void test_alias(void) {
  step("alias");
  volatile uint32_t *u = (volatile uint32_t *)RAM_ALIAS(alias_buf);
  check(csr_mcachectl(MCACHECTL_DFLUSH) == 0, "flush", 0);
  u[0] = 0x11111111u;                       /* memory: old value */
  check(alias_buf[0] == 0x11111111u, "cached read of alias write", alias_buf[0]);
  alias_buf[0] = 0x22222222u;               /* dirty line in the D-cache */
  check(u[0] == 0x11111111u, "alias bypasses dirty line", u[0]);
  check(csr_mcachectl(MCACHECTL_DCLEAN) == 0, "clean", 0);
  check(u[0] == 0x22222222u, "alias sees cleaned data", u[0]);
  u[1] = 0x33333333u;                       /* line still cached with the old word */
  (void)alias_buf[1];
  u[1] = 0x44444444u;
  check(alias_buf[1] != 0x44444444u, "stale cached copy before flush", alias_buf[1]);
  check(csr_mcachectl(MCACHECTL_DFLUSH) == 0, "flush", 0);
  check(alias_buf[1] == 0x44444444u, "cached read after flush", alias_buf[1]);
}

static void test_unmapped(void) {
  step("unmapped");
  exc_count = 0;
  volatile uint32_t *p = (volatile uint32_t *)0x2000F000u;   /* inside the debug range */
  (void)*p;
  check(exc_count == 1, "load fault taken", exc_count);
  check(last_mcause == 5u, "load access fault", last_mcause);
  check(exc_mtval == 0x2000F000u, "mtval", exc_mtval);
  p = (volatile uint32_t *)0x40000000u;
  *p = 1;
  check(exc_count == 2, "store fault taken", exc_count);
  check(last_mcause == 7u, "store access fault", last_mcause);
}

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

#define NDIRTY 64
static volatile uint32_t dirty_buf[NDIRTY] __attribute__((aligned(16)));

static void fill_dirty(uint32_t seed) {
  check(csr_mcachectl(MCACHECTL_DCLEAN) == 0, "pre-clean", 0);
  for (unsigned i = 0; i < NDIRTY; i++) dirty_buf[i] = seed ^ (i * 0x9E3779B9u);
  /* the data is only in the D-cache: memory (alias) still has the old copy */
  volatile uint32_t *u = (volatile uint32_t *)RAM_ALIAS(dirty_buf);
  unsigned in_mem = 0;
  for (unsigned i = 0; i < NDIRTY; i++) in_mem += (u[i] == (seed ^ (i * 0x9E3779B9u)));
  check(in_mem == 0, "data dirty in D-cache only", in_mem);
}
static unsigned count_ok(volatile uint32_t *p, uint32_t seed) {
  unsigned ok = 0;
  for (unsigned i = 0; i < NDIRTY; i++) ok += (p[i] == (seed ^ (i * 0x9E3779B9u)));
  return ok;
}

static void test_dirty_refused(void) {
  step("dirtyref");
  uint32_t cnt0 = PMU(PMU_SLEEP_CNT);
  PMU(PMU_STATUS) = PMU_ST_ERR_DIRTY;
  fill_dirty(0xD1D1D1D1u);
  INTC(INTC_ENABLE) = IRQ_WTIMER;
  wt_arm(12000);
  pm_test_skip_clean = 1;
  int r = pm_suspend(PMU_MODE_SLEEP);
  pm_test_skip_clean = 0;
  check(r == 0, "refused sleep returns 0", (uint32_t)r);
  check(PMU(PMU_STATUS) & PMU_ST_ERR_DIRTY, "ERR_DIRTY", PMU(PMU_STATUS));
  check(PMU(PMU_SLEEP_CNT) == cnt0, "no power-off", PMU(PMU_SLEEP_CNT));
  check(count_ok(dirty_buf, 0xD1D1D1D1u) == NDIRTY, "dirty data intact", 0);
  PMU(PMU_STATUS) = PMU_ST_ERR_DIRTY;
  wt_stop();
  INTC(INTC_ENABLE) = 0;
}

static void test_sleep_dirty(void) {
  step("sleep");
  uint32_t cnt0 = PMU(PMU_SLEEP_CNT);
  fill_dirty(0x5EE95EE9u);
  volatile uint32_t stack_word = 0xA5A5F00Du;
  INTC(INTC_ENABLE) = IRQ_WTIMER;
  wt_arm(12000);
  int r = pm_suspend(PMU_MODE_SLEEP);   /* cleans the dirty lines, then WFI */
  check(r == 1, "resumed from SLEEP", (uint32_t)r);
  check(pm_boot_status & PMU_ST_RESUME, "boot status RESUME", pm_boot_status);
  check(pm_boot_reason == 0, "boot reason", pm_boot_reason);
  check(PMU(PMU_SLEEP_CNT) == cnt0 + 1, "power-off count", PMU(PMU_SLEEP_CNT));
  check(stack_word == 0xA5A5F00Du, "stack", stack_word);
  check(count_ok(dirty_buf, 0x5EE95EE9u) == NDIRTY, "data through cache", 0);
  check(count_ok((volatile uint32_t *)RAM_ALIAS(dirty_buf), 0x5EE95EE9u) == NDIRTY,
        "data in memory", 0);
  wt_stop();
  INTC(INTC_ENABLE) = 0;
  /* mtvec/mie restored from the context: the timer interrupt still works */
  test_timer_irq();
}

/* Phase 1: request SLEEP with a corrupted context CRC. After the wake-up the
 * ROM must refuse the context and cold-boot; main() continues in phase 2. */
static void test_crc_fail_start(void) {
  step("crcfail");
  PERSIST->phase = 2;
  PERSIST->fails = fails;
  PERSIST->sleep_cnt = PMU(PMU_SLEEP_CNT);
  INTC(INTC_ENABLE) = IRQ_WTIMER;
  wt_arm(12000);
  uart_flush();
  pm_test_crc_flip = 1;
  int r = pm_suspend(PMU_MODE_SLEEP);
  /* only reached if the CPU was not powered off or the bad context resumed */
  pm_test_crc_flip = 0;
  check(0, "returned from pm_suspend with a bad CRC", (uint32_t)r);
}

static void test_crc_fail_end(void) {
  step("crcfail/cold-boot");
  fails = PERSIST->fails;
  check(pm_boot_status & PMU_ST_RESUME, "PMU reported a resume", pm_boot_status);
  check(pm_boot_reason == 4, "context rejected for its CRC", pm_boot_reason);
  check(PMU(PMU_SLEEP_CNT) == PERSIST->sleep_cnt + 1, "power-off happened", PMU(PMU_SLEEP_CNT));
  check(!(PMU(PMU_STATUS) & PMU_ST_RESUME), "resume flag cleared", PMU(PMU_STATUS));
}

int main(void) {
  /* wake sources used by this test (doc/SPEC.md: firmware enables them in mie) */
  __asm__ volatile("csrw mie, %0" ::"r"(MIE_MEIE));
  __asm__ volatile("csrw mtvec, %0" ::"r"((uintptr_t)&trap_handler));

  if (PERSIST->magic == PERSIST_MAGIC && PERSIST->phase == 2) {
    PERSIST->magic = 0;
    uart_puts("\nlp-soc boot_test (after cold reboot)\n");
    test_crc_fail_end();
  } else {
    PERSIST->magic = PERSIST_MAGIC;
    PERSIST->phase = 1;
    uart_puts("\nlp-soc boot_test\n");
    step("boot");
    check(pm_boot_reason == 1, "cold boot", pm_boot_reason);
    test_ramexec();
    test_mtime();
    test_timer_irq();
    test_alias();
    test_unmapped();
    test_dirty_refused();
    test_sleep_dirty();
    test_crc_fail_start();
  }

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
