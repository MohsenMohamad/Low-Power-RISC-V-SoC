/* Validation: CSRs / counters and synchronous exceptions. */
#include "test.h"
#include "arch.h"
#include "trap.h"
#include "drivers.h"
#include "platform_api.h"
#ifdef ARCH_RV32M
#include "csr.h"
#endif

/* ------------------------------------------------------------ counters */
static int t_counters(void)
{
    uint64_t c0 = arch_cycles();
    uint64_t i0 = arch_instret();
    uint32_t n = 100;
    __asm__ volatile("1: addi %0, %0, -1\n bnez %0, 1b" : "+r"(n));
    uint64_t i1 = arch_instret();
    uint64_t c1 = arch_cycles();
    /* 200 loop instructions plus the counter-read sequence */
    printf_("    instret delta %u, cycle delta %u\n", (unsigned)(i1 - i0), (unsigned)(c1 - c0));
    CHECK(i1 - i0 >= 200 && i1 - i0 < 260);
    CHECK(c1 - c0 >= i1 - i0);
    CHECK(arch_cycles() > c1);
    return TEST_PASS;
}
TEST(1, "csr_counters", CAP_COUNTERS, t_counters);

#ifdef ARCH_RV32M
static int t_mregs(void)
{
    static const uint32_t pat[] = {0u, 0xFFFFFFFFu, 0xA5A5A5A5u, 0x5A5A5A5Au, 0x80000001u};
    uint32_t saved = csr_read(mscratch);
    for (unsigned i = 0; i < ARRAY_SIZE(pat); i++) {
        csr_write(mscratch, pat[i]);
        CHECK_EQ(csr_read(mscratch), pat[i]);
    }
    /* read-modify-write semantics return the old value */
    csr_write(mscratch, 0x0000F0F0u);
    CHECK_EQ(csr_swap(mscratch, 0x12345678u), 0x0000F0F0u);
    CHECK_EQ(csr_set(mscratch, 0x80000000u), 0x12345678u);
    CHECK_EQ(csr_clear(mscratch, 0x00000078u), 0x92345678u);
    CHECK_EQ(csr_read(mscratch), 0x92345600u);
    /* immediate forms */
    uint32_t old;
    __asm__ volatile("csrrwi %0, mscratch, 0x15" : "=r"(old));
    CHECK_EQ(old, 0x92345600u);
    __asm__ volatile("csrrsi %0, mscratch, 0x0A" : "=r"(old));
    CHECK_EQ(old, 0x15u);
    __asm__ volatile("csrrci %0, mscratch, 0x01" : "=r"(old));
    CHECK_EQ(old, 0x1Fu);
    CHECK_EQ(csr_read(mscratch), 0x1Eu);
    csr_write(mscratch, saved);

    /* identification */
    uint32_t misa = csr_read(misa);
    CHECK((misa >> 30) == 1);                 /* MXL = 32     */
    CHECK(misa & (1u << ('I' - 'A')));
    CHECK(misa & (1u << ('M' - 'A')));
    CHECK_EQ(csr_read(mhartid), 0);
    (void)csr_read(mvendorid);
    (void)csr_read(marchid);
    (void)csr_read(mimpid);

    /* mstatus.MIE toggles, MPP is M (machine-mode only) */
    uint32_t st = csr_read(mstatus);
    csr_set(mstatus, MSTATUS_MIE);
    CHECK(csr_read(mstatus) & MSTATUS_MIE);
    csr_clear(mstatus, MSTATUS_MIE);
    CHECK(!(csr_read(mstatus) & MSTATUS_MIE));
    CHECK_EQ((csr_read(mstatus) & MSTATUS_MPP) >> 11, 3);
    csr_write(mstatus, st);

    /* mie: the three machine interrupt enables are writable */
    uint32_t mie = csr_read(mie);
    csr_write(mie, MIP_MSIP | MIP_MTIP | MIP_MEIP);
    CHECK_EQ(csr_read(mie) & (MIP_MSIP | MIP_MTIP | MIP_MEIP), MIP_MSIP | MIP_MTIP | MIP_MEIP);
    csr_write(mie, 0);
    CHECK_EQ(csr_read(mie) & (MIP_MSIP | MIP_MTIP | MIP_MEIP), 0);
    csr_write(mie, mie);

    /* mtvec: direct mode, 4-byte aligned base */
    uint32_t tv = csr_read(mtvec);
    csr_write(mtvec, tv + 0x100);
    CHECK_EQ(csr_read(mtvec), tv + 0x100);
    csr_write(mtvec, tv);
    CHECK_EQ(csr_read(mtvec), tv);

    /* mcycle / minstret are writable counters */
    csr_write(minstret, 0);
    uint32_t ir = csr_read(minstret);
    CHECK(ir < 16);
    return TEST_PASS;
}
TEST(2, "csr_machine_regs", CAP_MCSR, t_mregs);

static int t_mip(void)
{
    timer_cancel();
    timer_set_msip(0);
    CHECK(!(csr_read(mip) & (MIP_MTIP | MIP_MSIP)));
    timer_set_cmp(timer_now());               /* due now, MTIE disabled */
    for (int i = 0; i < 1000 && !(csr_read(mip) & MIP_MTIP); i++) ;
    CHECK(csr_read(mip) & MIP_MTIP);
    timer_cancel();
    CHECK(!(csr_read(mip) & MIP_MTIP));
    timer_set_msip(1);
    CHECK(csr_read(mip) & MIP_MSIP);
    timer_set_msip(0);
    CHECK(!(csr_read(mip) & MIP_MSIP));
    return TEST_PASS;
}
TEST(3, "csr_mip_pending", CAP_MCSR | CAP_CLINT, t_mip);
#endif

/* ------------------------------------------------------------ exceptions */
static volatile uint32_t ex_cause, ex_epc, ex_tval, ex_count;

static void exc_record(trap_frame_t *f)
{
    ex_cause = f->cause;
    ex_epc   = f->epc;
    ex_tval  = f->tval;
    ex_count = ex_count + 1;
    f->epc  += 4;                    /* skip the trapping instruction */
}

static void exc_arm(void)
{
    ex_cause = ex_epc = ex_tval = 0xFFFFFFFFu;
    ex_count = 0;
    trap_set_exc_handler(exc_record);
}

static int t_ecall(void)
{
    uint32_t pc;
    exc_arm();
    __asm__ volatile("la %0, 1f\n1: ecall" : "=&r"(pc) :: "memory");
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_ECALL_M);
    CHECK_EQ(ex_epc, pc);
    return TEST_PASS;
}
TEST(10, "exc_ecall", 0, t_ecall);

static int t_ebreak(void)
{
    uint32_t pc;
    exc_arm();
    __asm__ volatile("la %0, 1f\n1: ebreak" : "=&r"(pc) :: "memory");
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_BREAKPOINT);
    CHECK_EQ(ex_epc, pc);
    return TEST_PASS;
}
TEST(11, "exc_ebreak", 0, t_ebreak);

static int t_illegal(void)
{
    uint32_t pc;
    exc_arm();
    __asm__ volatile("la %0, 1f\n1: .word 0x0000007b" : "=&r"(pc) :: "memory");  /* custom-3 */
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_ILLEGAL);
    CHECK_EQ(ex_epc, pc);
    CHECK_EQ(ex_tval, 0x0000007bu);
    __asm__ volatile("la %0, 1f\n1: .word 0x00000000" : "=&r"(pc) :: "memory");  /* all-zero */
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 2);
    CHECK_EQ(ex_cause, EXC_ILLEGAL);
    CHECK_EQ(ex_epc, pc);
    return TEST_PASS;
}
TEST(12, "exc_illegal_insn", 0, t_illegal);

static int t_misaligned(void)
{
    static volatile uint32_t buf[4] __attribute__((aligned(16)));
    uint32_t pc, v, a = (uint32_t)(uintptr_t)&buf[1] + 1;
    exc_arm();
    __asm__ volatile("la %0, 1f\n1: lw %1, 0(%2)" : "=&r"(pc), "=&r"(v) : "r"(a) : "memory");
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_LOAD_MISALIGNED);
    CHECK_EQ(ex_epc, pc);
    CHECK_EQ(ex_tval, a);
    __asm__ volatile("la %0, 1f\n1: lh %1, 2(%2)" : "=&r"(pc), "=&r"(v) : "r"(a) : "memory");
    CHECK_EQ(ex_count, 2);
    CHECK_EQ(ex_cause, EXC_LOAD_MISALIGNED);
    CHECK_EQ(ex_tval, a + 2);
    __asm__ volatile("la %0, 1f\n1: sw zero, 4(%1)" : "=&r"(pc) : "r"(a) : "memory");
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 3);
    CHECK_EQ(ex_cause, EXC_STORE_MISALIGNED);
    CHECK_EQ(ex_epc, pc);
    CHECK_EQ(ex_tval, a + 4);
    return TEST_PASS;
}
TEST(13, "exc_misaligned", CAP_MISALIGN, t_misaligned);

static int t_access_fault(void)
{
    uint32_t pc, v;
    const uint32_t bad = 0x60000000u;        /* unmapped on every platform */
    exc_arm();
    __asm__ volatile("la %0, 1f\n1: lw %1, 0(%2)" : "=&r"(pc), "=&r"(v) : "r"(bad) : "memory");
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_LOAD_FAULT);
    CHECK_EQ(ex_epc, pc);
    CHECK_EQ(ex_tval, bad);
    __asm__ volatile("la %0, 1f\n1: sw zero, 8(%1)" : "=&r"(pc) : "r"(bad) : "memory");
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 2);
    CHECK_EQ(ex_cause, EXC_STORE_FAULT);
    CHECK_EQ(ex_tval, bad + 8);
    return TEST_PASS;
}
TEST(14, "exc_access_fault", CAP_ACCFAULT, t_access_fault);

uint32_t trap_regs_check(void);

static int t_regs_preserved(void)
{
    exc_arm();
    uint32_t r = trap_regs_check();
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 1);
    CHECK_EQ(ex_cause, EXC_ECALL_M);
    if (r) printf_("    register x%u corrupted by trap\n", (unsigned)r);
    CHECK_EQ(r, 0);
    return TEST_PASS;
}
TEST(15, "exc_regs_preserved", 0, t_regs_preserved);

static int t_nested_sequence(void)
{
    /* many back-to-back traps: handler state must not leak between them */
    exc_arm();
    for (int i = 0; i < 50; i++) {
        __asm__ volatile("ecall" ::: "memory");
        __asm__ volatile("ebreak" ::: "memory");
    }
    trap_set_exc_handler(0);
    CHECK_EQ(ex_count, 100);
    CHECK_EQ(ex_cause, EXC_BREAKPOINT);
    return TEST_PASS;
}
TEST(16, "exc_back_to_back", 0, t_nested_sequence);
