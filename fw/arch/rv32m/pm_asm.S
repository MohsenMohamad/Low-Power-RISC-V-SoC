/* int pm_clean_and_wfi(uint32_t pmu_ctrl, uint32_t do_clean)
 * Final power-down step (doc/SOC_REGMAP.md "Low-power entry", step 3-4):
 * clean the D-cache with mcachectl bit 2, check bit 31 (write-back error),
 * write PMU CTRL, WFI. Nothing is written to cacheable memory after the clean
 * (no stack use), so the cleaned state is exactly what survives power-off.
 * Returns 0 if the CPU was not powered down, -1 on a write-back error. */
#include "platform.h"

    .section .text.pm_asm, "ax"
    .globl pm_clean_and_wfi
    .balign 4
pm_clean_and_wfi:
#if PLATFORM_HAS_SOC
    beqz a1, 1f
    csrwi 0x7C0, 4                  /* D-cache clean, stalls until complete */
    csrr t1, 0x7C0
    bltz t1, 2f                     /* bit 31: write-back error */
1:
    li t0, PMU_BASE
    sw a0, PMU_CTRL(t0)
    fence
#endif
    wfi
    li a0, 0
    ret
#if PLATFORM_HAS_SOC
2:
    li a0, -1
    ret
#endif
