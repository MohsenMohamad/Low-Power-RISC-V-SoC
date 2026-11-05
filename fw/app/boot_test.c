/*
 * Integrated-SoC boot test (stage 1, ported in stage 2 to the boot ROM and
 * resume ABI of doc/BOOT_ABI.md). Loaded as an application image; checks,
 * self-checking over the UART:
 *
 *   boot      power-on cold boot: the ROM validated the image header and CRC,
 *             recorded rst_cause POR / reason "no resume", started the image
 *   ramexec   the application executes from RAM through the I-cache
 *   mtime     time CSR (mtime exported through the snapshot CDC) tracks the
 *             machine-timer register
 *   timerirq  machine-timer interrupt taken through mtvec (MTIE, mstatus.MIE)
 *   alias     uncached RAM alias 0x3000_0000: bypasses the write-back D-cache
 *   unmapped  unmapped addresses return SLVERR (load / store access fault)
 *   dirtyref  SLEEP refused while the D-cache holds dirty data (ERR_DIRTY)
 *   sleep     full SLEEP / resume with dirty data in the D-cache: the data is
 *             written back by pm_suspend, the CPU is powered off, the boot ROM
 *             verifies the context and resumes
 *   crcfail   a resume context with a bad CRC is rejected and the ROM
 *             cold-boots (reason CRC); progress across that reboot is kept in
 *             the persistent area through the uncached alias
 *
 * Prints "PASS" or "FAIL 0x<n>"; every check prints "  ERR ..." on failure.
 */
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "platform_api.h"
#include "pm.h"
#include "trap.h"
#include "csr.h"

/* State kept across the deliberate cold reboot (persistent area, uncached). */
struct persist {
    uint32_t magic;
    uint32_t phase;
    uint32_t fails;
    uint32_t sleep_cnt;
    uint32_t cold_boots;
};
#define PERSIST_MAGIC 0xB007CAFEu
#define PERSIST ((volatile struct persist *)(PERSIST_ADDR + RAM_UNCACHED_OFFSET))

static uint32_t fails;

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

/* ------------------------------------------------------------- traps */
static volatile uint32_t irq_count, last_mcause, exc_count, exc_mtval;

static void mti_handler(trap_frame_t *f)
{
    last_mcause = f->cause;
    irq_count = irq_count + 1;
    timer_cancel();                          /* acknowledge: mtip falls */
}

static void exc_handler(trap_frame_t *f)
{
    last_mcause = f->cause;
    exc_mtval = f->tval;
    exc_count = exc_count + 1;
    f->epc += 4;                             /* skip the faulting instruction */
}

/* ------------------------------------------------------------- tests */
static __attribute__((noinline)) uint32_t current_pc(void)
{
    uint32_t pc;
    __asm__ volatile("auipc %0, 0" : "=r"(pc));
    return pc;
}

static void test_boot(void)
{
    step("boot");
    volatile handoff_t *h = HANDOFF;
    check(h->boot_status == BOOT_COLD, "cold boot", h->boot_status);
    check(h->rst_cause == RST_POR, "power-on reset", h->rst_cause);
    check(h->boot_reason == REASON_NO_RESUME, "reason", h->boot_reason);
    check(h->rom_version == ROM_VERSION, "rom version", h->rom_version);
    check(h->cold_boots == 1, "cold boots", h->cold_boots);
}

static void test_ramexec(void)
{
    step("ramexec");
    uint32_t pc = current_pc();
    check(pc >= APP_BASE && pc < RAM_BASE + RAM_SIZE, "pc in RAM", pc);
}

static void test_mtime(void)
{
    step("mtime");
    for (int i = 0; i < 4; i++) {
        uint32_t m0 = (uint32_t)timer_now();
        uint32_t t = csr_read(time);
        uint32_t m1 = (uint32_t)timer_now();
        /* rdtime is a coherent snapshot that lags the counter by a few clk_aon
         * cycles (doc/CPU_SOC_INTERFACE.md): m0 - 16 <= t <= m1 */
        check((uint32_t)(t - (m0 - 16u)) <= (uint32_t)(m1 - (m0 - 16u)), "rdtime window", t);
    }
    uint32_t a = csr_read(time), b;
    for (volatile int i = 0; i < 50; i++) {}
    b = csr_read(time);
    check(b > a, "rdtime advances", b - a);
}

static void test_timer_irq(void)
{
    step("timerirq");
    irq_count = 0;
    trap_set_irq_handler(IRQ_MTI, mti_handler);
    uint64_t due = timer_now() + 300u;
    timer_set_cmp(due);
    arch_irq_enable(IRQ_MTI);
    arch_irq_global_enable();
    uint32_t spins = 0;
    while (irq_count == 0 && spins < 200000u) spins++;
    (void)arch_irq_save();
    arch_irq_disable(IRQ_MTI);
    check(irq_count == 1, "timer irq count", irq_count);
    check(last_mcause == (CAUSE_IRQ_FLAG | IRQ_MTI), "mcause", last_mcause);
    check(timer_now() >= due, "irq not early", (uint32_t)timer_now());
}

static volatile uint32_t alias_buf[8] __attribute__((aligned(16)));

static void test_alias(void)
{
    step("alias");
    volatile uint32_t *u = UNCACHED(alias_buf);
    check(dcache_flush() == 0, "flush", 0);
    u[0] = 0x11111111u;                       /* memory: old value */
    check(alias_buf[0] == 0x11111111u, "cached read of alias write", alias_buf[0]);
    alias_buf[0] = 0x22222222u;               /* dirty line in the D-cache */
    check(u[0] == 0x11111111u, "alias bypasses dirty line", u[0]);
    check(dcache_clean() == 0, "clean", 0);
    check(u[0] == 0x22222222u, "alias sees cleaned data", u[0]);
    u[1] = 0x33333333u;                       /* line still cached with the old word */
    (void)alias_buf[1];
    u[1] = 0x44444444u;
    check(alias_buf[1] != 0x44444444u, "stale cached copy before flush", alias_buf[1]);
    check(dcache_flush() == 0, "flush", 0);
    check(alias_buf[1] == 0x44444444u, "cached read after flush", alias_buf[1]);
}

static void test_unmapped(void)
{
    step("unmapped");
    exc_count = 0;
    trap_set_exc_handler(exc_handler);
    volatile uint32_t *p = (volatile uint32_t *)0x2000F000u;   /* inside the debug range */
    (void)*p;
    check(exc_count == 1, "load fault taken", exc_count);
    check(last_mcause == EXC_LOAD_FAULT, "load access fault", last_mcause);
    check(exc_mtval == 0x2000F000u, "mtval", exc_mtval);
    p = (volatile uint32_t *)0x40000000u;
    *p = 1;
    check(exc_count == 2, "store fault taken", exc_count);
    check(last_mcause == EXC_STORE_FAULT, "store access fault", last_mcause);
    trap_set_exc_handler(0);
}

#define NDIRTY 64
static volatile uint32_t dirty_buf[NDIRTY] __attribute__((aligned(16)));

static void fill_dirty(uint32_t seed)
{
    check(dcache_clean() == 0, "pre-clean", 0);
    for (unsigned i = 0; i < NDIRTY; i++) dirty_buf[i] = seed ^ (i * 0x9E3779B9u);
    /* the data is only in the D-cache: memory (alias) still has the old copy */
    volatile uint32_t *u = UNCACHED(dirty_buf);
    unsigned in_mem = 0;
    for (unsigned i = 0; i < NDIRTY; i++) in_mem += (u[i] == (seed ^ (i * 0x9E3779B9u)));
    check(in_mem == 0, "data dirty in D-cache only", in_mem);
}

static unsigned count_ok(volatile uint32_t *p, uint32_t seed)
{
    unsigned ok = 0;
    for (unsigned i = 0; i < NDIRTY; i++) ok += (p[i] == (seed ^ (i * 0x9E3779B9u)));
    return ok;
}

static void test_dirty_refused(void)
{
    step("dirtyref");
    uint32_t cnt0 = pmu_sleep_count();
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    fill_dirty(0xD1D1D1D1u);
    intc_set_enabled(IRQ_WTIMER);
    wtimer_start(12000, 0);
    int r = pm_suspend(PM_SLEEP, PM_F_NO_CLEAN);
    check(r == PM_ABORTED, "refused sleep reported as aborted", (uint32_t)r);
    check(pmu_status() & PMU_ST_ERR_DIRTY, "ERR_DIRTY", pmu_status());
    check(pmu_sleep_count() == cnt0, "no power-off", pmu_sleep_count());
    check(count_ok(dirty_buf, 0xD1D1D1D1u) == NDIRTY, "dirty data intact", 0);
    pmu_clear_status(PMU_ST_ERR_DIRTY);
    wtimer_stop();
    intc_set_enabled(0);
}

static void test_sleep_dirty(void)
{
    step("sleep");
    uint32_t cnt0 = pmu_sleep_count();
    fill_dirty(0x5EE95EE9u);
    volatile uint32_t stack_word = 0xA5A5F00Du;
    intc_set_enabled(IRQ_WTIMER);
    wtimer_start(12000, 0);
    int r = pm_suspend(PM_SLEEP, 0);       /* cleans the dirty lines, then WFI */
    volatile handoff_t *h = HANDOFF;
    check(r == PM_RESUMED, "resumed from SLEEP", (uint32_t)r);
    check(h->boot_status == BOOT_RESUMED, "boot status", h->boot_status);
    check(h->boot_reason == REASON_OK, "boot reason", h->boot_reason);
    check(h->pmu_status & PMU_ST_RESUME, "PMU resume flag", h->pmu_status);
    check(pmu_sleep_count() == cnt0 + 1, "power-off count", pmu_sleep_count());
    check(stack_word == 0xA5A5F00Du, "stack", stack_word);
    check(count_ok(dirty_buf, 0x5EE95EE9u) == NDIRTY, "data through cache", 0);
    check(count_ok(UNCACHED(dirty_buf), 0x5EE95EE9u) == NDIRTY, "data in memory", 0);
    check(pmu_read(PMU_SCRATCH1) == 0, "resume magic consumed", pmu_read(PMU_SCRATCH1));
    check(h->ctx.magic == 0, "context consumed", h->ctx.magic);
    wtimer_stop();
    intc_set_enabled(0);
    /* mtvec/mie restored from the context: the timer interrupt still works */
    test_timer_irq();
    arch_irq_enable(IRQ_MEI);
}

/* Phase 1: request SLEEP with a corrupted context CRC. After the wake-up the
 * ROM must refuse the context and cold-boot; main() continues in phase 2. */
static void test_crc_fail_start(void)
{
    step("crcfail");
    PERSIST->phase = 2;
    PERSIST->fails = fails;
    PERSIST->sleep_cnt = pmu_sleep_count();
    PERSIST->cold_boots = HANDOFF->cold_boots;
    intc_set_enabled(IRQ_WTIMER);
    wtimer_start(12000, 0);
    uart_flush();
    int r = pm_suspend(PM_SLEEP, PM_F_BAD_CRC);
    /* only reached if the CPU was not powered off or the bad context resumed */
    check(0, "returned from pm_suspend with a bad CRC", (uint32_t)r);
}

static void test_crc_fail_end(void)
{
    step("crcfail/cold-boot");
    volatile handoff_t *h = HANDOFF;
    fails = PERSIST->fails;
    check(h->boot_status == BOOT_RESUME_BADCTX, "boot status", h->boot_status);
    check(h->rst_cause == RST_SLEEP, "woke from SLEEP", h->rst_cause);
    check(h->boot_reason == REASON_CRC, "context rejected for its CRC", h->boot_reason);
    check(h->bad_resumes == 1, "bad resumes", h->bad_resumes);
    check(h->cold_boots == PERSIST->cold_boots + 1, "cold boots", h->cold_boots);
    check(pmu_sleep_count() == PERSIST->sleep_cnt + 1, "power-off happened", pmu_sleep_count());
    check(!(pmu_status() & PMU_ST_RESUME), "resume flag cleared", pmu_status());
    check(pmu_read(PMU_SCRATCH1) == 0, "resume magic consumed", pmu_read(PMU_SCRATCH1));
}

int main(void)
{
    arch_init();
    /* wake source used by this test (doc/SPEC.md: firmware enables it in mie) */
    arch_irq_enable(IRQ_MEI);

    if (PERSIST->magic == PERSIST_MAGIC && PERSIST->phase == 2) {
        PERSIST->magic = 0;
        puts_("\nlp-soc boot_test (after cold reboot)\n");
        test_crc_fail_end();
    } else {
        PERSIST->magic = PERSIST_MAGIC;
        PERSIST->phase = 1;
        puts_("\nlp-soc boot_test\n");
        test_boot();
        test_ramexec();
        test_mtime();
        test_timer_irq();
        arch_irq_enable(IRQ_MEI);
        test_alias();
        test_unmapped();
        test_dirty_refused();
        test_sleep_dirty();
        test_crc_fail_start();
    }
    platform_exit(fails);
}
