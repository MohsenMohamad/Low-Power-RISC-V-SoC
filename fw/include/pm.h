/* Power management: IDLE, SLEEP, DEEP_SLEEP and DVFS (pm/pm.c).
 * Firmware side of the sequences in doc/SOC_REGMAP.md ("Low-power entry")
 * and doc/BOOT_ABI.md (context save / resume). */
#ifndef PM_H
#define PM_H

#include <stdint.h>
#include "handoff.h"

enum pm_state { PM_IDLE = 0, PM_SLEEP = 1, PM_DEEP_SLEEP = 2 };

enum pm_result {
    PM_WOKE     = 0,    /* IDLE: clock was gated, woke up by interrupt        */
    PM_RESUMED  = 1,    /* SLEEP/DEEP_SLEEP: powered off, context restored    */
    PM_ABORTED  = 2,    /* the requested transition did not complete          */
    PM_EINVAL   = -1,   /* bad argument, or no wake source enabled in mie     */
    PM_EWB      = -2,   /* D-cache clean reported a write-back error: entry abandoned */
    PM_ETIMEOUT = -3,   /* DVFS completion never reported                     */
};

/* Test hooks for pm_suspend(): */
#define PM_F_NO_CLEAN   (1u << 0)   /* skip the D-cache clean (PMU must refuse) */
#define PM_F_BAD_CRC    (1u << 1)   /* store a wrong context CRC (ROM must reject) */

/* PMU.WAKE_MASK = the wake sources enabled in mie. */
void pm_sync_wake_mask(void);
/* WFI with the PMU wake mask set from mie. */
void pm_wfi(void);
/* Clock-gated wait (PMU IDLE) for an interrupt enabled in mie. */
int  pm_idle(void);
/* Save context, clean D$, power PD_CPU down until a wake source fires.
 * Wake sources must be enabled in mie (and at their origin) by the caller. */
int  pm_suspend(enum pm_state st, uint32_t flags);
/* Change the CPU operating point (0 = slowest .. 2 = fastest). The PMU
 * switches while the CPU clock is gated (IDLE). */
int  pm_set_opp(uint32_t op);

/* Context save/restore (arch/<cpu>/ctx.S). pm_ctx_save returns 0 when the
 * context was saved and 1 when execution resumes through pm_ctx_restore. */
int  pm_ctx_save(pm_ctx_t *ctx) __attribute__((returns_twice));
void pm_ctx_restore(const pm_ctx_t *ctx) __attribute__((noreturn));

/* Shared with the boot ROM. */
uint32_t pm_ctx_crc(const pm_ctx_t *ctx);
int      pm_ctx_valid(const pm_ctx_t *ctx);
void     pm_ctx_seal(pm_ctx_t *ctx);

/* Low-level tail of the power-down path (arch/<cpu>/pm_asm.S): D-cache clean
 * via mcachectl (unless do_clean = 0), check the write-back error bit, write
 * PMU CTRL, WFI. No stack or cached-memory store after the clean. Returns 0
 * if the CPU was not powered down, -1 on a write-back error (no WFI). */
int  pm_clean_and_wfi(uint32_t pmu_ctrl, uint32_t do_clean);

#endif
