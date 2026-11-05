/* Context save / restore for SLEEP and DEEP_SLEEP (PicoRV32).
 * Same contract as arch/rv32m/ctx.S.
 *
 * arch[] layout: 0 IRQ mask, 1 soft mtvec
 */
#include "handoff.h"
#include "picorv32_ops.h"

#define R(n) (CTX_OFF_REGS + 4 * (n))
#define A(n) (CTX_OFF_ARCH + 4 * (n))

    .section .text.pm_ctx, "ax"
    .globl pm_ctx_save
    .balign 4
pm_ctx_save:
    sw ra,  R(0)(a0)
    sw sp,  R(1)(a0)
    sw gp,  R(2)(a0)
    sw tp,  R(3)(a0)
    sw s0,  R(4)(a0)
    sw s1,  R(5)(a0)
    sw s2,  R(6)(a0)
    sw s3,  R(7)(a0)
    sw s4,  R(8)(a0)
    sw s5,  R(9)(a0)
    sw s6,  R(10)(a0)
    sw s7,  R(11)(a0)
    sw s8,  R(12)(a0)
    sw s9,  R(13)(a0)
    sw s10, R(14)(a0)
    sw s11, R(15)(a0)
    /* read the IRQ mask: mask everything, then put the old value back */
    li t1, -1
    MASKIRQ(t0, t1)
    MASKIRQ(x0, t0)
    sw t0,  A(0)(a0)
    li t1, HANDOFF_ADDR
    lw t0,  HANDOFF_SOFT_MTVEC(t1)
    sw t0,  A(1)(a0)
    sw zero, A(2)(a0)
    sw zero, A(3)(a0)
    sw zero, A(4)(a0)
    sw zero, A(5)(a0)
    sw zero, A(6)(a0)
    sw zero, A(7)(a0)
    li a0, 0
    ret

    .globl pm_ctx_restore
    .balign 4
pm_ctx_restore:
    lw t0,  A(1)(a0)
    li t1, HANDOFF_ADDR
    sw t0,  HANDOFF_SOFT_MTVEC(t1)
    lw ra,  R(0)(a0)
    lw sp,  R(1)(a0)
    lw gp,  R(2)(a0)
    lw tp,  R(3)(a0)
    lw s0,  R(4)(a0)
    lw s1,  R(5)(a0)
    lw s2,  R(6)(a0)
    lw s3,  R(7)(a0)
    lw s4,  R(8)(a0)
    lw s5,  R(9)(a0)
    lw s6,  R(10)(a0)
    lw s7,  R(11)(a0)
    lw s8,  R(12)(a0)
    lw s9,  R(13)(a0)
    lw s10, R(14)(a0)
    lw s11, R(15)(a0)
    lw t0,  A(0)(a0)
    MASKIRQ(x0, t0)
    li a0, 1
    ret
