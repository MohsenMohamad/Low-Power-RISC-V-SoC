/* CPU port: standard RISC-V machine mode (in-house core, Spike). */
#include "arch.h"
#include "csr.h"

extern void trap_entry(void);

void arch_init(void)
{
    csr_clear(mstatus, MSTATUS_MIE);
    csr_write(mie, 0);
    csr_write(mtvec, (uint32_t)(uintptr_t)trap_entry);   /* direct mode */
}

uint32_t arch_caps(void)
{
    return CAP_MCSR | CAP_COUNTERS | CAP_MISALIGN | CAP_ACCFAULT;
}

uint32_t arch_irq_save(void)
{
    return csr_clear(mstatus, MSTATUS_MIE) & MSTATUS_MIE;
}

void arch_irq_restore(uint32_t state)
{
    if (state & MSTATUS_MIE) csr_set(mstatus, MSTATUS_MIE);
}

void arch_irq_global_enable(void)
{
    csr_set(mstatus, MSTATUS_MIE);
}

void arch_irq_enable(uint32_t code)
{
    csr_set(mie, 1u << code);
}

void arch_irq_disable(uint32_t code)
{
    csr_clear(mie, 1u << code);
}

int arch_irq_is_enabled(uint32_t code)
{
    return (csr_read(mie) >> code) & 1u;
}

void arch_wfi(void)
{
    __asm__ volatile("wfi" ::: "memory");
}

uint64_t arch_cycles(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = csr_read(mcycleh);
        lo  = csr_read(mcycle);
        hi2 = csr_read(mcycleh);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

uint64_t arch_instret(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = csr_read(minstreth);
        lo  = csr_read(minstret);
        hi2 = csr_read(minstreth);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
