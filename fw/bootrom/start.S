/* Boot ROM entry, reset vector 0x0000_0000 (doc/BOOT_ABI.md).
 * Every power-up (cold or resume) starts here. The ROM uses only its own RAM
 * window RAM_BASE+0x400..0xFFF for .data/.bss/stack, so a resume never
 * touches application memory. */
#include "handoff.h"

    .section .text.start, "ax"
    .globl _start
_start:
    /* registers are undefined after reset / power-up (the OFF-state
     * corruption model makes them X in 4-state simulation): clear them so
     * no undefined value is ever stored */
    .irp r,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\r, 0
    .endr
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
