/* void pm_flush_and_wfi(uint32_t pmu_ctrl, uint32_t do_flush)
 * Final power-down step. After the D$ flush nothing is written to cacheable
 * memory (no stack use), so the flushed state is exactly what survives. */
#include "platform.h"

    .section .text.pm_asm, "ax"
    .globl pm_flush_and_wfi
    .balign 4
pm_flush_and_wfi:
#if PLATFORM_HAS_SOC
    beqz a1, 1f
    li t0, CACHE_BASE
    li t1, CACHE_CMD_FLUSH_ALL
    sw t1, CACHE_DC_CMD(t0)         /* blocks until the flush is complete */
1:
    li t0, PMU_BASE
    sw a0, PMU_CTRL(t0)
    fence
#endif
    wfi
    ret
