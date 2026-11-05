/* PMU driver: power-state requests, wake sources, reset cause, counters.
 * The power-state sequencing itself lives in pm/pm.c. */
#include "drivers.h"

#define PMU(off) REG32(PMU_BASE + (off))

uint32_t pmu_read(uint32_t off)
{
    return PMU(off);
}

void pmu_write(uint32_t off, uint32_t v)
{
    PMU(off) = v;
}

int pmu_present(void)
{
    return PMU(PMU_ID) == PMU_ID_VALUE;
}

uint32_t pmu_rst_cause(void)
{
    return PMU(PMU_RST_CAUSE);
}

void pmu_set_mode(uint32_t mode, int dvfs_req)
{
    PMU(PMU_CTRL) = (mode & 3u) | (dvfs_req ? PMU_CTRL_DVFS_REQ : 0u);
}

void pmu_set_wake(uint32_t mask)
{
    PMU(PMU_WAKE_EN) = mask;
}

uint32_t pmu_cur_op(void)
{
    return PMU_ST_CUR_OP(PMU(PMU_STATUS));
}

void pmu_clear_counters(void)
{
    PMU(PMU_CNT_IDLE)  = 0;
    PMU(PMU_CNT_SLEEP) = 0;
    PMU(PMU_CNT_DEEP)  = 0;
    PMU(PMU_CNT_DVFS)  = 0;
    PMU(PMU_CNT_ABORT) = 0;
}

void pmu_sw_reset(void)
{
    /* dirty cache lines would be discarded by the boot ROM */
    dcache_flush_all();
    uart_flush();
    PMU(PMU_SWRST) = PMU_SWRST_KEY;
    for (;;) ;
}
