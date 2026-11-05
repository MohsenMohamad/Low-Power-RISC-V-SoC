/* void pm_flush_and_wfi(uint32_t pmu_ctrl, uint32_t do_flush)
 * Final power-down step (PicoRV32: WFI = waitirq). */
#include "platform.h"
#include "picorv32_ops.h"

    .section .text.pm_asm, "ax"
    .globl pm_flush_and_wfi
    .balign 4
pm_flush_and_wfi:
    beqz a1, 1f
    li t0, CACHE_BASE
    li t1, CACHE_CMD_FLUSH_ALL
    sw t1, CACHE_DC_CMD(t0)         /* blocks until the flush is complete */
1:
    li t0, PMU_BASE
    sw a0, PMU_CTRL(t0)
    WAITIRQ(t1)
    ret
