/* Power management: IDLE, SLEEP, DEEP_SLEEP and DVFS (pm/pm.c). */
#ifndef PM_H
#define PM_H

#include <stdint.h>
#include "handoff.h"

enum pm_state { PM_IDLE = 0, PM_SLEEP = 1, PM_DEEP_SLEEP = 2 };

enum pm_result {
    PM_WOKE     = 0,    /* IDLE: woke up by interrupt                       */
    PM_RESUMED  = 1,    /* SLEEP/DEEP_SLEEP: powered off, context restored  */
    PM_ABORTED  = 2,    /* power-down refused (wake event already pending)  */
    PM_EINVAL   = -1,
};

/* Test hook: skip the D-cache flush before power-down. The saved context
 * then never reaches RAM and the boot ROM must fall back to a cold boot. */
#define PM_F_NO_FLUSH   (1u << 0)

/* Clock-gated wait for any interrupt (IDLE state). */
int  pm_idle(void);
/* Save context, flush D$, power PD_CPU down until a PMU wake source fires.
 * Returns PM_RESUMED after the boot ROM restored the context. */
int  pm_suspend(enum pm_state st, uint32_t flags);
/* Change the CPU operating point (0 = fastest .. 2 = slowest). The switch is
 * performed by the PMU while the CPU clock is gated. */
int  pm_set_opp(uint32_t op);

/* Context save/restore (arch/<cpu>/ctx.S). pm_ctx_save returns 0 when the
 * context was saved and 1 when execution resumes through pm_ctx_restore. */
int  pm_ctx_save(pm_ctx_t *ctx) __attribute__((returns_twice));
void pm_ctx_restore(const pm_ctx_t *ctx) __attribute__((noreturn));

/* Shared with the boot ROM. */
uint32_t pm_ctx_crc(const pm_ctx_t *ctx);
int      pm_ctx_valid(const pm_ctx_t *ctx);
void     pm_ctx_seal(pm_ctx_t *ctx);

/* Low-level tail of the power-down path (arch/<cpu>/pm_asm.S): optional
 * D$ flush, write PMU CTRL, WFI. No stack or cached-memory accesses after the
 * flush. Returns only if the power-down did not happen. */
void pm_flush_and_wfi(uint32_t pmu_ctrl, uint32_t do_flush);

#endif
