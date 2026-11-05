/*
 * CPU port: PicoRV32 (bring-up platform).
 *
 * PicoRV32 has no M-mode CSR file. This port maps its IRQ scheme onto the
 * standard trap model used by the rest of the firmware:
 *   - the fixed IRQ vector (0x10, boot ROM) jumps through the soft mtvec word
 *     in the handoff block (HANDOFF->soft_mtvec)
 *   - pending-IRQ bits are translated to mcause codes; the faulting
 *     instruction is decoded to tell ecall / ebreak / illegal apart and to
 *     compute mtval for misaligned accesses
 *   - mstatus.MIE and mie are emulated with the maskirq instruction
 */
#include "arch.h"
#include "trap.h"
#include "handoff.h"
#include "picorv32_ops.h"

extern void trap_entry(void);

static uint32_t src_en;     /* PicoRV32 IRQ bits of enabled sources (mie) */
static uint32_t glob_en;    /* mstatus.MIE                                 */

static uint32_t code_bit(uint32_t code)
{
    switch (code) {
    case IRQ_MTI: return PICO_IRQ_MTI_BIT;
    case IRQ_MSI: return PICO_IRQ_MSI_BIT;
    case IRQ_MEI: return PICO_IRQ_MEI_BIT;
    default:      return 0;
    }
}

static void apply_mask(void)
{
    /* exception lines are never masked (a masked one halts the core) */
    uint32_t unmasked = PICO_IRQ_EXC_BIT | PICO_IRQ_BUSERR_BIT | (glob_en ? src_en : 0);
    pico_maskirq(~unmasked);
}

void arch_init(void)
{
    glob_en = 0;
    src_en  = 0;
    HANDOFF->soft_mtvec = (uint32_t)(uintptr_t)trap_entry;
    apply_mask();
}

uint32_t arch_caps(void)
{
    return CAP_COUNTERS | CAP_MISALIGN;
}

uint32_t arch_irq_save(void)
{
    uint32_t old = glob_en;
    glob_en = 0;
    apply_mask();
    return old;
}

void arch_irq_restore(uint32_t state)
{
    if (state) {
        glob_en = 1;
        apply_mask();
    }
}

void arch_irq_global_enable(void)
{
    glob_en = 1;
    apply_mask();
}

void arch_irq_enable(uint32_t code)
{
    src_en |= code_bit(code);
    apply_mask();
}

void arch_irq_disable(uint32_t code)
{
    src_en &= ~code_bit(code);
    apply_mask();
}

int arch_irq_is_enabled(uint32_t code)
{
    return (src_en & code_bit(code)) != 0;
}

void arch_wfi(void)
{
    (void)pico_waitirq();
}

uint64_t arch_cycles(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi));
        __asm__ volatile("rdcycle %0"  : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

uint64_t arch_instret(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("rdinstreth %0" : "=r"(hi));
        __asm__ volatile("rdinstret %0"  : "=r"(lo));
        __asm__ volatile("rdinstreth %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* Called from trap_entry.S. pend = q1 (pending IRQ bits), q0 = return pc.
 * Returns the pc to resume at (written back to q0). */
uint32_t pico_trap(trap_frame_t *f, uint32_t pend, uint32_t q0);
uint32_t pico_trap(trap_frame_t *f, uint32_t pend, uint32_t q0)
{
    f->x[0]   = 0;
    f->status = pend;
    f->tval   = 0;
    f->epc    = q0;

    if (pend & (PICO_IRQ_EXC_BIT | PICO_IRQ_BUSERR_BIT)) {
        /* q0 points past the trapping instruction (no compressed ISA) */
        uint32_t pc   = q0 - 4;
        uint32_t insn = *(volatile const uint32_t *)(uintptr_t)pc;
        f->epc = pc;
        if (pend & PICO_IRQ_EXC_BIT) {
            if (insn == 0x00000073u)      f->cause = EXC_ECALL_M;
            else if (insn == 0x00100073u) f->cause = EXC_BREAKPOINT;
            else { f->cause = EXC_ILLEGAL; f->tval = insn; }
        } else {
            uint32_t opc  = insn & 0x7Fu;
            uint32_t base = f->x[(insn >> 15) & 31u];
            if (opc == 0x03u) {
                f->cause = EXC_LOAD_MISALIGNED;
                f->tval  = base + (uint32_t)((int32_t)insn >> 20);
            } else if (opc == 0x23u) {
                int32_t imm = ((int32_t)(insn & 0xFE000000u) >> 20) | (int32_t)((insn >> 7) & 0x1Fu);
                f->cause = EXC_STORE_MISALIGNED;
                f->tval  = base + (uint32_t)imm;
            } else {
                f->cause = EXC_INSN_MISALIGNED;
                f->epc   = q0;
                f->tval  = q0;
            }
        }
        trap_dispatch(f);
    }
    if (pend & PICO_IRQ_MSI_BIT) { f->cause = CAUSE_IRQ_FLAG | IRQ_MSI; trap_dispatch(f); }
    if (pend & PICO_IRQ_MTI_BIT) { f->cause = CAUSE_IRQ_FLAG | IRQ_MTI; trap_dispatch(f); }
    if (pend & PICO_IRQ_MEI_BIT) { f->cause = CAUSE_IRQ_FLAG | IRQ_MEI; trap_dispatch(f); }
    return f->epc;
}
