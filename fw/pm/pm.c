/*
 * Power management.
 *
 * SLEEP / DEEP_SLEEP power-down path (firmware side of the PMU sequence):
 *   1. disable interrupts
 *   2. save CPU context into the handoff block (pm_ctx_save) and seal it
 *      with a CRC
 *   3. flush the D-cache (context, stack and all dirty data reach RAM)
 *   4. program PMU CTRL.MODE and execute WFI; the PMU then gates the clock,
 *      isolates, resets and switches PD_CPU off
 * Wake-up: the PMU powers PD_CPU up and releases reset, the boot ROM sees
 * RST_CAUSE = SLEEP/DEEP, validates the context and calls pm_ctx_restore(),
 * which returns a second time from pm_ctx_save() with value 1.
 */
#include "pm.h"
#include "arch.h"
#include "drivers.h"
#include "lib.h"

#define DVFS_MAX_WAITS 64

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

int pm_idle(void)
{
    pmu_set_mode(PMU_MODE_IDLE, 0);
    arch_wfi();
    return PM_WOKE;
}

int pm_suspend(enum pm_state st, uint32_t flags)
{
    if (st == PM_IDLE) return pm_idle();
    if (st != PM_SLEEP && st != PM_DEEP_SLEEP) return PM_EINVAL;
    if ((pmu_read(PMU_WAKE_EN) & 7u) == 0) return PM_EINVAL;   /* would never wake */

    pm_ctx_t *ctx = (pm_ctx_t *)&HANDOFF->ctx;
    uint32_t irq = arch_irq_save();

    if (pm_ctx_save(ctx) == 0) {
        pm_ctx_seal(ctx);
        pm_flush_and_wfi(st == PM_SLEEP ? PMU_MODE_SLEEP : PMU_MODE_DEEP,
                         (flags & PM_F_NO_FLUSH) ? 0u : 1u);
        /* Still powered: the PMU refused the power-down because a wake
         * event was already pending. */
        ctx->magic = 0;
        pmu_set_mode(PMU_MODE_IDLE, 0);
        arch_irq_restore(irq);
        return PM_ABORTED;
    }

    /* Resumed through the boot ROM. Invalidate the context so that it can
     * never be restored twice. */
    ctx->magic = 0;
    arch_irq_restore(irq);
    return PM_RESUMED;
}

int pm_set_opp(uint32_t op)
{
    if (op >= PMU_NUM_OPP) return PM_EINVAL;

    uint32_t irq      = arch_irq_save();
    uint32_t intc_en  = intc_enabled();
    uint32_t ev_ie    = pmu_read(PMU_EVENT_IE);
    int      mei_en   = arch_irq_is_enabled(IRQ_MEI);
    int      rc       = -2;

    /* the DVFS_DONE event (PMU -> intc -> MEIP) ends the WFI */
    pmu_write(PMU_EVENT, PMU_EV_DVFS_DONE);
    pmu_write(PMU_EVENT_IE, ev_ie | PMU_EV_DVFS_DONE);
    intc_enable(INTC_SRC_PMU);
    arch_irq_enable(IRQ_MEI);

    pmu_write(PMU_DVFS_OP, op);
    pmu_set_mode(PMU_MODE_IDLE, 1);
    for (int i = 0; i < DVFS_MAX_WAITS; i++) {
        arch_wfi();
        if (pmu_read(PMU_EVENT) & PMU_EV_DVFS_DONE) {
            rc = (pmu_cur_op() == op) ? 0 : -1;
            break;
        }
    }
    if (rc == -2) pmu_set_mode(PMU_MODE_IDLE, 0);   /* withdraw the request */

    pmu_write(PMU_EVENT, PMU_EV_DVFS_DONE);
    pmu_write(PMU_EVENT_IE, ev_ie);
    intc_set_enabled(intc_en);
    if (!mei_en) arch_irq_disable(IRQ_MEI);
    arch_irq_restore(irq);
    return rc;
}
