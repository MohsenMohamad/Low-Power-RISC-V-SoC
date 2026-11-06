/* Spike harness for the divergence kernel (scripts/run_fw.py dbg): linked so
 * that dbg_div_kernel has the same address as in the debug application
 * (--section-start), memory at the RAM window and at the trace buffer page.
 * _start sets the return address, jumps to the kernel, then ends the run
 * through HTIF. */
    .section .text.start, "ax"
    .globl _start
_start:
    la   ra, 2f
    j    dbg_div_kernel
2:  li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
3:  j    3b

    .section .tohost, "aw"
    .align 6
    .globl tohost, fromhost
tohost:   .word 0, 0
fromhost: .word 0, 0
