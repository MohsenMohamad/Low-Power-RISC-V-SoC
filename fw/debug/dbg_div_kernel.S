/* Divergence-check kernel (doc/DEBUG_SPEC.md section 9, test 6): a pure
 * RV32IM instruction stream with no input and no platform-dependent data, so
 * Spike started at dbg_div_kernel executes exactly what the SoC retired. It
 * ends by freezing the trace buffer (a store to its CTRL register), followed
 * by nops that cover the freeze latency. Linked into the debug application
 * and, at the same address, into the Spike harness spike_divk.S
 * (scripts/run_fw.py dbg); tools/dbg_decode.py --spike-log compares the
 * dumped trace with the Spike commit log. Position independent. */
#include "soc.h"

    .section .text.dbg_div, "ax"
    .globl dbg_div_kernel
dbg_div_kernel:
    li   t0, 0x12345678
    li   t1, 0
    li   t2, 40
1:
    mul  t3, t0, t0
    xor  t0, t0, t3
    srli t3, t0, 7
    add  t1, t1, t3
    divu t4, t1, t2
    remu t5, t0, t2
    add  t0, t0, t4
    addi t2, t2, -1
    bnez t2, 1b
    li   a0, DBG_TRACE_BASE + TRC_CTRL
    li   t6, TRC_CTRL_FREEZE
    sw   t6, 0(a0)
    .rept 16
    nop
    .endr
    ret
