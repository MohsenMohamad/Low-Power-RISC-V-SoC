# Smoke test: arithmetic, memory, branches, M extension, a trap, then pass.
  .section .text.init
  .globl _start
_start:
  la    t0, handler
  csrw  mtvec, t0
  li    a0, 10
  li    a1, 0
loop:
  add   a1, a1, a0
  addi  a0, a0, -1
  bnez  a0, loop          # a1 = 55
  la    s0, buf
  sw    a1, 0(s0)
  lw    a2, 0(s0)         # load-use next
  addi  a3, a2, 1
  sb    a3, 5(s0)
  lbu   a4, 5(s0)
  li    t1, 7
  mul   a5, a1, t1
  div   a6, a5, t1
  rem   a7, a5, a0        # rem by zero
  ecall                   # handler skips it
  lw    t2, 2(s0)         # misaligned -> trap
  csrr  t3, minstret
  csrr  t4, mcause
  fence.i
  li    t5, 1
  la    t6, tohost
  sw    t5, 0(t6)
1: j 1b

handler:
  csrr  t0, mepc
  addi  t0, t0, 4
  csrw  mepc, t0
  mret

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .word 0
  .align 6
  .globl fromhost
fromhost: .word 0

  .data
  .align 4
buf: .space 64
