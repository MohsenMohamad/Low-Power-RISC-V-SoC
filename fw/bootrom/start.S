/* Boot ROM entry. Reset vector 0x0000_0000.
 * PicoRV32: the IRQ vector is fixed at 0x10 and dispatches through the
 * soft mtvec word in the handoff block (original t0 kept in q2). */
#include "handoff.h"
#ifdef ARCH_PICORV32
#include "picorv32_ops.h"
#endif

    .section .text.start, "ax"
    .globl _start
_start:
    j rom_reset

#ifdef ARCH_PICORV32
    .org 0x10
irq_vector:
    SETQ(Q2, t0)
    li t0, HANDOFF_ADDR
    lw t0, HANDOFF_SOFT_MTVEC(t0)
    jr t0
#endif

rom_reset:
    li sp, ROM_STACK_TOP
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    /* .data: copy from ROM to RAM */
    la a0, __data_load
    la a1, __data_start
    la a2, __data_end
1:  bgeu a1, a2, 2f
    lw t0, 0(a0)
    sw t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j 1b
2:  /* .bss */
    la a1, __bss_start
    la a2, __bss_end
3:  bgeu a1, a2, 4f
    sw zero, 0(a1)
    addi a1, a1, 4
    j 3b
4:  call rom_main
5:  j 5b
