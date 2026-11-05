/* Context save / restore for SLEEP and DEEP_SLEEP (standard M-mode CPU).
 *
 * pm_ctx_save(ctx)    : stores callee-saved state + CSRs, returns 0.
 * pm_ctx_restore(ctx) : reloads it and returns 1 from the matching
 *                       pm_ctx_save() call (setjmp/longjmp semantics).
 *
 * arch[] layout: 0 mstatus, 1 mie, 2 mtvec, 3 mscratch
 */
#include "handoff.h"

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
    csrr t0, mstatus
    sw t0,  A(0)(a0)
    csrr t0, mie
    sw t0,  A(1)(a0)
    csrr t0, mtvec
    sw t0,  A(2)(a0)
    csrr t0, mscratch
    sw t0,  A(3)(a0)
    sw zero, A(4)(a0)
    sw zero, A(5)(a0)
    sw zero, A(6)(a0)
    sw zero, A(7)(a0)
    li a0, 0
    ret

    .globl pm_ctx_restore
    .balign 4
pm_ctx_restore:
    /* interrupts stay off until mstatus is restored last */
    csrci mstatus, 8
    lw t0,  A(1)(a0)
    csrw mie, t0
    lw t0,  A(2)(a0)
    csrw mtvec, t0
    lw t0,  A(3)(a0)
    csrw mscratch, t0
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
    csrw mstatus, t0
    li a0, 1
    ret
