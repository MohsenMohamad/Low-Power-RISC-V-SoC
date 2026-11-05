/*
 * Boot ROM entry: cold boot vs. resume detection and CPU context
 * save/restore for SLEEP / DEEP_SLEEP.
 *
 * Resume protocol: before WFI, pm_suspend() saves the callee-saved context to
 * pm_ctx (main RAM, retained), writes its address to PMU.SCRATCH0 and
 * PM_RESUME_MAGIC to PMU.SCRATCH1. After a power cycle the core restarts here;
 * if PMU.STATUS.RESUME is set and the magic matches, the context is restored
 * and pm_suspend() returns 1 to its caller. Otherwise this is a cold boot.
 */
#include "soc.h"

  .section .text.start, "ax"
  .globl _start
_start:
  li    t0, PMU_BASE
  lw    t1, PMU_STATUS(t0)
  li    t2, PMU_ST_RESUME
  and   t3, t1, t2
  beqz  t3, cold_boot
  lw    t3, PMU_SCRATCH1(t0)
  li    t4, PM_RESUME_MAGIC
  bne   t3, t4, cold_boot

  /* ---- resume ---- */
  la    t3, pm_boot_status
  sw    t1, 0(t3)
  li    t2, (PMU_ST_RESUME | PMU_ST_RESUME_DEEP)
  sw    t2, PMU_STATUS(t0)          /* W1C resume flags */
  lw    a0, PMU_SCRATCH0(t0)
  j     pm_resume

cold_boot:
  li    t2, (PMU_ST_RESUME | PMU_ST_RESUME_DEEP)
  sw    t2, PMU_STATUS(t0)
  sw    zero, PMU_SCRATCH1(t0)
  la    sp, _stack_top
  /* copy .data */
  la    t0, _data_load
  la    t1, _data_start
  la    t2, _data_end
1:bgeu  t1, t2, 2f
  lw    t3, 0(t0)
  sw    t3, 0(t1)
  addi  t0, t0, 4
  addi  t1, t1, 4
  j     1b
2:/* zero .bss */
  la    t1, _bss_start
  la    t2, _bss_end
3:bgeu  t1, t2, 4f
  sw    zero, 0(t1)
  addi  t1, t1, 4
  j     3b
4:call  main
5:j     5b

/* int pm_suspend(uint32_t mode)
 *   returns 0 if the CPU was not powered off (IDLE, or the wake-up arrived
 *   before power-down), 1 after a resume from SLEEP / DEEP_SLEEP. */
  .text
  .globl pm_suspend
pm_suspend:
  la    t0, pm_ctx
  sw    ra,  0(t0)
  sw    sp,  4(t0)
  sw    gp,  8(t0)
  sw    tp, 12(t0)
  sw    s0, 16(t0)
  sw    s1, 20(t0)
  sw    s2, 24(t0)
  sw    s3, 28(t0)
  sw    s4, 32(t0)
  sw    s5, 36(t0)
  sw    s6, 40(t0)
  sw    s7, 44(t0)
  sw    s8, 48(t0)
  sw    s9, 52(t0)
  sw    s10, 56(t0)
  sw    s11, 60(t0)
  li    t1, PMU_BASE
  sw    t0, PMU_SCRATCH0(t1)
  li    t2, PM_RESUME_MAGIC
  sw    t2, PMU_SCRATCH1(t1)
  andi  a0, a0, 3
  ori   a0, a0, PMU_CTRL_LP_EN
  sw    a0, PMU_CTRL(t1)
  /* (D-cache clean + invalidate goes here with the in-house core) */
  wfi
  /* Still powered: IDLE, or a wake-up before the power-down point. */
  sw    zero, PMU_SCRATCH1(t1)
  li    a0, 0
  ret

pm_resume:
  lw    ra,  0(a0)
  lw    sp,  4(a0)
  lw    gp,  8(a0)
  lw    tp, 12(a0)
  lw    s0, 16(a0)
  lw    s1, 20(a0)
  lw    s2, 24(a0)
  lw    s3, 28(a0)
  lw    s4, 32(a0)
  lw    s5, 36(a0)
  lw    s6, 40(a0)
  lw    s7, 44(a0)
  lw    s8, 48(a0)
  lw    s9, 52(a0)
  lw    s10, 56(a0)
  lw    s11, 60(a0)
  li    t1, PMU_BASE
  sw    zero, PMU_SCRATCH1(t1)
  li    a0, 1
  ret

  .bss
  .balign 4
  .globl pm_ctx
pm_ctx:
  .space 64
  .globl pm_boot_status
pm_boot_status:
  .space 4
