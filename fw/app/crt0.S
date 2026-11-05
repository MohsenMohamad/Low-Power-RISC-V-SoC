/* Application startup. The image header is checked by the boot ROM before
 * it jumps to _start (cold boot only; a resume never comes through here). */
#include "handoff.h"

    .section .header, "a"
    .globl image_header
image_header:
    .word IMAGE_MAGIC
    .word 1                 /* header version             */
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
    la a0, __bss_start
    la a1, __bss_end
1:  bgeu a0, a1, 2f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 1b
2:  call main
    call platform_exit
3:  j 3b
