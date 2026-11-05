# Directed, self-checking test of the custom mcachectl CSR (0x7C0) and fence.i.
# COSIM: off
# Not co-simulated: the CSR is implementation specific (Spike treats it as
# illegal). Exercises D-cache clean, flush (clean+invalidate), I-cache
# invalidate, and checks data integrity across each operation.
#   tohost = 1 on pass, (2*n+1) on failure of check n.
  .section .text.init
  .globl _start
_start:
  la    t0, fail
  csrw  mtvec, t0
  la    s0, buf
  li    s1, 0
  li    s2, 1024              # 4 KB of data: two full ways' worth of lines
1:
  slli  t1, s1, 2
  add   t2, s0, t1
  xor   t3, s1, s2
  slli  t3, t3, 7
  add   t3, t3, s1
  sw    t3, 0(t2)             # dirty lines everywhere
  addi  s1, s1, 1
  blt   s1, s2, 1b

  li    gp, 1
  csrwi 0x7C0, 4              # D-cache clean (lines stay valid)
  csrr  t0, 0x7C0
  bltz  t0, fail              # bit31: write-back error
  jal   check_buf

  li    gp, 2
  csrwi 0x7C0, 1              # D-cache flush: clean + invalidate
  csrr  t0, 0x7C0
  bltz  t0, fail
  jal   check_buf             # every access misses and refills from memory

  li    gp, 3                 # self-modifying code + I-cache invalidate via CSR
  la    t0, slot
  li    t1, 0x02a00593        # li a1, 42
  sw    t1, 0(t0)
  csrwi 0x7C0, 4              # clean D-cache so memory holds the new instruction
  csrwi 0x7C0, 2              # invalidate I-cache
slot:
  nop
  li    t2, 42
  bne   a1, t2, fail

  li    gp, 4                 # same via fence.i
  la    t0, slot2
  li    t1, 0x00700593        # li a1, 7
  sw    t1, 0(t0)
  fence.i
slot2:
  nop
  li    t2, 7
  bne   a1, t2, fail

  li    gp, 5
  csrwi 0x7C0, 3              # flush D + invalidate I together
  jal   check_buf

  li    t0, 1
  j     done

check_buf:
  li    s1, 0
2:
  slli  t1, s1, 2
  add   t2, s0, t1
  lw    t4, 0(t2)
  xor   t3, s1, s2
  slli  t3, t3, 7
  add   t3, t3, s1
  bne   t3, t4, fail
  addi  s1, s1, 1
  blt   s1, s2, 2b
  ret

fail:
  slli  t0, gp, 1
  addi  t0, t0, 1
done:
  fence.i
  la    t1, tohost
  sw    t0, 0(t1)
3: j 3b

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .word 0
  .align 6
  .globl fromhost
fromhost: .word 0

  .data
  .align 12
buf: .space 4096
