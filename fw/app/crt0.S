/* Application startup (doc/BOOT_ABI.md). The image header is checked by the boot ROM before
 * it jumps to _start (cold boot only; a resume never comes through here). */
#include "handoff.h"

    .section .header, "a"
    .globl image_header
image_header:
    .word IMAGE_MAGIC
    .word IMAGE_VERSION     /* header version             */
    .word __image_start     /* load address               */
    .word __image_size      /* bytes incl. header         */
    .word _start            /* entry point                */
    .word 0                 /* CRC-32, patched by mkimage */
    .word 0, 0

    .section .text.start, "ax"
    .globl _start
_start:
    la sp, __stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    /* .data: copy from the image (LMA) to its run-time address, so the image
     * itself is never written (fw/platform/lpsoc/app.ld) */
    la a0, __data_start
    la a1, __data_end
    la a2, __data_lma
4:  bgeu a0, a1, 5f
    lw t0, 0(a2)
    sw t0, 0(a0)
    addi a0, a0, 4
    addi a2, a2, 4
    j 4b
5:  la a0, __bss_start
    la a1, __bss_end
1:  bgeu a0, a1, 2f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 1b
2:  call main
    call platform_exit
3:  j 3b
