/*
 * Power management (doc/SOC_REGMAP.md "Low-power entry", doc/BOOT_ABI.md).
 *
 * SLEEP / DEEP_SLEEP:
 *   1. disable interrupts (mstatus.MIE); wake sources stay enabled in mie
 *   2. save the CPU context at CTX_ADDR (pm_ctx_save), seal it (magic, CRC-32)
 *   3. PMU.SCRATCH0 = CTX_ADDR, PMU.SCRATCH1 = RESUME_MAGIC
 *   4. clean the D-cache (mcachectl bit 2), check bit 31, write PMU.CTRL, WFI
 *      (pm_clean_and_wfi: no cached store after the clean)
 * The PMU then gates the clock, isolates, resets and switches PD_CPU off; on
 * the wake event it powers PD_CPU up and the boot ROM restores the context,
 * so pm_ctx_save() returns a second time with 1.
 * If WFI returns, the CPU was not powered down: the PMU refused (no
 * cache_clean / idle_ack, STATUS.ERR_DIRTY) or a wake event came first.
 */
#include "pm.h"
#include "arch.h"
#include "drivers.h"
#include "lib.h"

#define DVFS_MAX_WAITS 16

uint32_t pm_ctx_crc(const pm_ctx_t *ctx)
{
    return crc32(ctx->regs, sizeof(ctx->regs) + sizeof(ctx->arch));
}

int pm_ctx_valid(const pm_ctx_t *ctx)
{
    return ctx->magic == CTX_MAGIC && ctx->crc == pm_ctx_crc(ctx);
}

void pm_ctx_seal(pm_ctx_t *ctx)
{
    ctx->crc   = pm_ctx_crc(ctx);
    ctx->magic = CTX_MAGIC;
}

void pm_wfi(void)
{
    arch_wfi();
}

int pm_idle(void)
{
#if PLATFORM_HAS_SOC
    pmu_set_mode(PMU_MODE_IDLE);
#endif
    pm_wfi();
    return PM_WOKE;
}

#if PLATFORM_HAS_SOC
int pm_suspend(enum pm_state st, uint32_t flags)
{
    if (st == PM_IDLE) return pm_idle();
    if (st != PM_SLEEP && st != PM_DEEP_SLEEP) return PM_EINVAL;
    if (!arch_irq_wake_sources()) return PM_EINVAL;     /* WFI would never end */

    pm_ctx_t *ctx = (pm_ctx_t *)CTX_ADDR;
    uint32_t irq = arch_irq_save();
    int r;

    if (pm_ctx_save(ctx) == 0) {
        pm_ctx_seal(ctx);
        if (flags & PM_F_BAD_CRC) ctx->crc ^= 1u;
        pmu_write(PMU_SCRATCH0, CTX_ADDR);
        pmu_write(PMU_SCRATCH1, RESUME_MAGIC);
        r = pm_clean_and_wfi((st == PM_SLEEP ? PMU_MODE_SLEEP : PMU_MODE_DEEP) | PMU_CTRL_LP_EN,
                             (flags & PM_F_NO_CLEAN) ? 0u : 1u);
        /* Still powered: no power-down happened. */
        pmu_write(PMU_SCRATCH1, 0);
        ctx->magic = 0;
        pmu_set_mode(PMU_MODE_IDLE);
        arch_irq_restore(irq);
        return r < 0 ? PM_EWB : PM_ABORTED;
    }

    /* Resumed through the boot ROM (which consumed SCRATCH1). The PMU mode is
     * sticky: return to IDLE so a later plain WFI does not power down. */
    ctx->magic = 0;
    pmu_set_mode(PMU_MODE_IDLE);
    arch_irq_restore(irq);
    return PM_RESUMED;
}

int pm_set_opp(uint32_t op)
{
    if (op >= PMU_NUM_OPP) return PM_EINVAL;
    if (pmu_cur_op() == op) return 0;       /* the PMU runs no sequence for it */

    uint32_t irq     = arch_irq_save();
    uint32_t mie     = arch_irq_mask_save(1u << IRQ_MEI);   /* only DVFS_DONE wakes */
    uint32_t intc_en = intc_enabled();
    uint32_t irq_en  = pmu_read(PMU_IRQ_EN);
    int      rc      = PM_ETIMEOUT;

    pmu_clear_status(PMU_ST_DVFS_DONE);
    pmu_write(PMU_IRQ_EN, PMU_IRQ_EN_DVFS_DONE);
    intc_set_enabled(IRQ_PMU);
    pmu_write(PMU_DVFS, op);
    pmu_set_mode(PMU_MODE_IDLE);
    for (int i = 0; i < DVFS_MAX_WAITS; i++) {
        pm_wfi();
        uint32_t s = pmu_status();
        if (s & PMU_ST_DVFS_DONE) {
            rc = (PMU_ST_CUR_OP(s) == op) ? 0 : PM_ABORTED;
            break;
        }
    }
    pmu_clear_status(PMU_ST_DVFS_DONE);
    pmu_write(PMU_IRQ_EN, irq_en);
    intc_set_enabled(intc_en);
    arch_irq_mask_restore(mie);
    arch_irq_restore(irq);
    return rc;
}
#else
int pm_suspend(enum pm_state st, uint32_t flags)
{
    (void)flags;
    return st == PM_IDLE ? pm_idle() : PM_EINVAL;
}

int pm_set_opp(uint32_t op)
{
    (void)op;
    return PM_EINVAL;
}
#endif
