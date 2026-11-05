/*
 * Boot ROM entry for the integrated SoC (in-house RV32IM core, write-back
 * D-cache): cold boot vs. resume detection, CRC-checked context restore, and
 * the SLEEP / DEEP_SLEEP suspend path.
 *
 * Resume protocol (interim stage-1 ABI; doc/BOOT_ABI.md is a later-stage item,
 * see doc/INTEGRATION_REPORT.md):
 *   pm_suspend() saves ra, sp, gp, tp, s0..s11 (words 0..15) and mstatus,
 *   mie, mtvec, mscratch (words 16..19) to pm_ctx in RAM, stores the CRC-32
 *   (IEEE, reflected, init/xorout 0xFFFFFFFF) of words 0..19 in word 20,
 *   writes &pm_ctx to PMU.SCRATCH0 and PM_RESUME_MAGIC to PMU.SCRATCH1,
 *   cleans the D-cache (mcachectl bit 2), checks the write-back error bit and
 *   executes WFI. After a power cycle the core restarts here. The context is
 *   restored only if PMU.STATUS.RESUME is set, the magic matches, the pointer
 *   lies in RAM and the CRC matches (doc/SPEC.md); otherwise this is a cold
 *   boot. pm_boot_status records PMU.STATUS at entry, and pm_boot_reason
 *   records why a resume was rejected (0 none, 1 no resume flag, 2 magic,
 *   3 pointer, 4 CRC).
 */
#include "soc.h"

#define CTX_WORDS   20          /* words covered by the CRC */
#define CTX_BYTES   (4 * (CTX_WORDS + 1))
#define CSR_MCACHECTL 0x7C0

  .section .text.start, "ax"
  .globl _start
_start:
  /* Registers are undefined after reset / power-up: clear them so no
   * undefined value can ever be stored or used (deterministic boot). */
  .irp r,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
  li    x\r, 0
  .endr
  li    s1, PMU_BASE
  lw    s2, PMU_STATUS(s1)           /* s2 = STATUS at entry */
  li    s3, 1                        /* s3 = reject reason */
  li    t2, PMU_ST_RESUME
  and   t3, s2, t2
  beqz  t3, cold_boot
  li    s3, 2
  lw    t3, PMU_SCRATCH1(s1)
  li    t4, PM_RESUME_MAGIC
  bne   t3, t4, cold_boot
  li    s3, 3
  lw    s0, PMU_SCRATCH0(s1)         /* s0 = context pointer */
  andi  t3, s0, 3
  bnez  t3, cold_boot
  li    t3, RAM_BASE
  bltu  s0, t3, cold_boot
  li    t3, (RAM_BASE + RAM_SIZE - CTX_BYTES)
  bgtu  s0, t3, cold_boot
  li    s3, 4
  mv    a0, s0
  li    a1, CTX_WORDS
  jal   ra, crc32_words
  lw    t3, (4 * CTX_WORDS)(s0)
  bne   a0, t3, cold_boot

  /* ---- resume ---- */
  la    t3, pm_boot_status
  sw    s2, 0(t3)
  la    t3, pm_boot_reason
  sw    zero, 0(t3)
  li    t2, (PMU_ST_RESUME | PMU_ST_RESUME_DEEP)
  sw    t2, PMU_STATUS(s1)           /* W1C resume flags */
  sw    zero, PMU_SCRATCH1(s1)       /* a context is restored at most once */
  mv    a0, s0
  j     pm_resume

cold_boot:
  li    t2, (PMU_ST_RESUME | PMU_ST_RESUME_DEEP)
  sw    t2, PMU_STATUS(s1)
  sw    zero, PMU_SCRATCH1(s1)
  la    sp, _stack_top
  /* copy .data (including RAM-resident code, section .ramtext) */
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
4:/* the copied code went through the D-cache: clean D, invalidate I */
  fence.i
  la    t3, pm_boot_status
  sw    s2, 0(t3)
  la    t3, pm_boot_reason
  sw    s3, 0(t3)
  call  main
5:j     5b

/* uint32_t crc32_words(const uint32_t *p, uint32_t n)
 * CRC-32 (IEEE 802.3, reflected, init and xorout 0xFFFFFFFF) over n
 * little-endian words, 4 bits per step with a 16-entry table in ROM.
 * Leaf routine: uses only a0-a1, t0-t4; usable before a stack exists. */
  .text
  .globl crc32_words
crc32_words:
  li    t0, -1                       /* crc */
  la    t4, crc32_nibble_tab
1:beqz  a1, 3f
  lw    t1, 0(a0)
  xor   t0, t0, t1
  li    t2, 8                        /* 8 nibbles per word */
2:andi  t3, t0, 15
  slli  t3, t3, 2
  add   t3, t3, t4
  lw    t3, 0(t3)
  srli  t0, t0, 4
  xor   t0, t0, t3
  addi  t2, t2, -1
  bnez  t2, 2b
  addi  a0, a0, 4
  addi  a1, a1, -1
  j     1b
3:not   a0, t0
  ret

  .section .rodata
  .balign 4
crc32_nibble_tab:
  .word 0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC
  .word 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C
  .word 0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C
  .word 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C
  .text

/* int pm_suspend(uint32_t mode)
 *   returns 0 if the CPU was not powered off (IDLE, a refused power-down, or
 *   a wake-up before the power-down point), 1 after a resume from SLEEP /
 *   DEEP_SLEEP, -1 if the D-cache clean reported a write-back error (the
 *   low-power entry is then abandoned).
 * Wake sources must be enabled in mie by the caller (doc/SPEC.md). */
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
  csrr  t1, mstatus
  sw    t1, 64(t0)
  csrr  t1, mie
  sw    t1, 68(t0)
  csrr  t1, mtvec
  sw    t1, 72(t0)
  csrr  t1, mscratch
  sw    t1, 76(t0)
  mv    t5, a0                       /* mode */
  mv    t6, ra
  mv    a0, t0
  li    a1, CTX_WORDS
  jal   ra, crc32_words
  mv    ra, t6
  la    t0, pm_ctx
  la    t1, pm_test_crc_flip         /* test hook: corrupt the stored CRC */
  lw    t1, 0(t1)
  xor   a0, a0, t1
  sw    a0, (4 * CTX_WORDS)(t0)
  li    t1, PMU_BASE
  sw    t0, PMU_SCRATCH0(t1)
  li    t2, PM_RESUME_MAGIC
  sw    t2, PMU_SCRATCH1(t1)
  andi  t5, t5, 3
  ori   t5, t5, PMU_CTRL_LP_EN
  sw    t5, PMU_CTRL(t1)
  /* Clean the D-cache: no cached store may follow before WFI. The test hook
   * pm_test_skip_clean leaves the dirty lines in place (the PMU must then
   * refuse the power-down). */
  la    t2, pm_test_skip_clean
  lw    t2, 0(t2)
  bnez  t2, 1f
  csrwi CSR_MCACHECTL, 4
  csrr  t2, CSR_MCACHECTL
  bltz  t2, 2f                       /* bit 31: write-back error */
1:wfi
  /* Still powered: IDLE, refused power-down, or wake before power-down. */
  sw    zero, PMU_SCRATCH1(t1)
  li    a0, 0
  ret
2:sw    zero, PMU_SCRATCH1(t1)
  sw    zero, PMU_CTRL(t1)           /* back to MODE=IDLE, LP_EN=0 */
  li    a0, -1
  ret

pm_resume:
  mv    t0, a0
  lw    ra,  0(t0)
  lw    sp,  4(t0)
  lw    gp,  8(t0)
  lw    tp, 12(t0)
  lw    s0, 16(t0)
  lw    s1, 20(t0)
  lw    s2, 24(t0)
  lw    s3, 28(t0)
  lw    s4, 32(t0)
  lw    s5, 36(t0)
  lw    s6, 40(t0)
  lw    s7, 44(t0)
  lw    s8, 48(t0)
  lw    s9, 52(t0)
  lw    s10, 56(t0)
  lw    s11, 60(t0)
  lw    t1, 72(t0)
  csrw  mtvec, t1
  lw    t1, 76(t0)
  csrw  mscratch, t1
  lw    t1, 68(t0)
  csrw  mie, t1
  lw    t1, 64(t0)                   /* mstatus last: may re-enable interrupts */
  csrw  mstatus, t1
  li    a0, 1
  ret

  .bss
  .balign 4
  .globl pm_ctx
pm_ctx:
  .space CTX_BYTES
  .globl pm_boot_status
pm_boot_status:
  .space 4
  .globl pm_boot_reason
pm_boot_reason:
  .space 4
  .globl pm_test_crc_flip
pm_test_crc_flip:
  .space 4
  .globl pm_test_skip_clean
pm_test_skip_clean:
  .space 4
