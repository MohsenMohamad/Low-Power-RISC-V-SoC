/* PicoRV32 custom IRQ instructions (custom-0 opcode). q0..q3 are encoded as
 * register numbers 0..3, i.e. written here as x0..x3. */
#ifndef PICORV32_OPS_H
#define PICORV32_OPS_H

#ifdef __ASSEMBLER__
/* getq rd, qN : rd = qN */
#define GETQ(rd, qs)    .insn r 0x0B, 4, 0, rd, qs, x0
/* setq qN, rs : qN = rs */
#define SETQ(qd, rs)    .insn r 0x0B, 2, 1, qd, rs, x0
#define RETIRQ          .insn r 0x0B, 0, 2, x0, x0, x0
/* maskirq rd, rs : rd = old mask, mask = rs (1 = masked) */
#define MASKIRQ(rd, rs) .insn r 0x0B, 6, 3, rd, rs, x0
/* waitirq rd : wait for any pending IRQ line, rd = pending bits */
#define WAITIRQ(rd)     .insn r 0x0B, 4, 4, rd, x0, x0
#define Q0 x0
#define Q1 x1
#define Q2 x2
#define Q3 x3
#else
#include <stdint.h>
static inline uint32_t pico_maskirq(uint32_t m)
{
    uint32_t old;
    __asm__ volatile(".insn r 0x0B, 6, 3, %0, %1, x0" : "=r"(old) : "r"(m) : "memory");
    return old;
}
static inline uint32_t pico_waitirq(void)
{
    uint32_t p;
    __asm__ volatile(".insn r 0x0B, 4, 4, %0, x0, x0" : "=r"(p) :: "memory");
    return p;
}
#endif

/* PicoRV32 IRQ line assignment on the bring-up SoC */
#define PICO_IRQ_EXC_BIT    (1u << 1)   /* ebreak / ecall / illegal insn  */
#define PICO_IRQ_BUSERR_BIT (1u << 2)   /* misaligned access              */
#define PICO_IRQ_MTI_BIT    (1u << 3)
#define PICO_IRQ_MSI_BIT    (1u << 4)
#define PICO_IRQ_MEI_BIT    (1u << 5)

#endif
