/* Register-level helpers for the validation suite. */
#include "handoff.h"

    .section .text.tests_asm, "ax"

/* uint32_t trap_regs_check(void)
 * Loads a pattern into x1 and x5..x31, executes ecall (the test handler
 * skips it) and verifies every register. Returns 0 or the number of the
 * first corrupted register. gp/tp/sp are not touched (used by the handler). */
    .globl trap_regs_check
    .balign 4
trap_regs_check:
    addi sp, sp, -64
    sw ra,  0(sp)
    sw s0,  4(sp)
    sw s1,  8(sp)
    sw s2, 12(sp)
    sw s3, 16(sp)
    sw s4, 20(sp)
    sw s5, 24(sp)
    sw s6, 28(sp)
    sw s7, 32(sp)
    sw s8, 36(sp)
    sw s9, 40(sp)
    sw s10, 44(sp)
    sw s11, 48(sp)

    .irp n, 1,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\n, (0xA5000000 + \n * 0x01010)
    .endr
    ecall
    .irp n, 1,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x4, (0xA5000000 + \n * 0x01010)
    beq x\n, x4, 1f
    li a0, \n
    j 9f
1:
    .endr
    li a0, 0
9:
    /* tp (x4) was used as scratch: it is not used by this firmware */
    li x4, 0
    lw ra,  0(sp)
    lw s0,  4(sp)
    lw s1,  8(sp)
    lw s2, 12(sp)
    lw s3, 16(sp)
    lw s4, 20(sp)
    lw s5, 24(sp)
    lw s6, 28(sp)
    lw s7, 32(sp)
    lw s8, 36(sp)
    lw s9, 40(sp)
    lw s10, 44(sp)
    lw s11, 48(sp)
    addi sp, sp, 64
    ret

/* uint32_t ctx_regs_check(pm_ctx_t *ctx)
 * Puts patterns in s0..s11, saves the context, clobbers s0..s11, restores
 * the context and checks that s0..s11 hold the patterns again.
 * Returns 0 or 100 + index of the first wrong s-register. */
    .globl ctx_regs_check
    .balign 4
ctx_regs_check:
    addi sp, sp, -64
    sw ra,  0(sp)
    sw s0,  4(sp)
    sw s1,  8(sp)
    sw s2, 12(sp)
    sw s3, 16(sp)
    sw s4, 20(sp)
    sw s5, 24(sp)
    sw s6, 28(sp)
    sw s7, 32(sp)
    sw s8, 36(sp)
    sw s9, 40(sp)
    sw s10, 44(sp)
    sw s11, 48(sp)
    sw a0, 52(sp)

    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    li s\n, (0x5C000000 + \n * 0x0101)
    .endr
    call pm_ctx_save
    bnez a0, 2f
    /* first return: clobber and restore */
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    li s\n, 0xDEADBEEF
    .endr
    lw a0, 52(sp)
    call pm_ctx_restore
2:  /* second return */
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    li t0, (0x5C000000 + \n * 0x0101)
    beq s\n, t0, 3f
    li a0, (100 + \n)
    j 9f
3:
    .endr
    li a0, 0
9:
    lw ra,  0(sp)
    lw s0,  4(sp)
    lw s1,  8(sp)
    lw s2, 12(sp)
    lw s3, 16(sp)
    lw s4, 20(sp)
    lw s5, 24(sp)
    lw s6, 28(sp)
    lw s7, 32(sp)
    lw s8, 36(sp)
    lw s9, 40(sp)
    lw s10, 44(sp)
    lw s11, 48(sp)
    addi sp, sp, 64
    ret
