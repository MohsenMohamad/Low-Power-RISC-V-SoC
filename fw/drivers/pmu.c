/* PMU driver (doc/SOC_REGMAP.md 0x2000_3000). Register access only; the
 * power-state sequences are in pm/pm.c. */
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

void pmu_set_mode(uint32_t mode)
{
    PMU(PMU_CTRL) = (mode & 3u) | PMU_CTRL_LP_EN;
}

uint32_t pmu_status(void)
{
    return PMU(PMU_STATUS);
}

void pmu_clear_status(uint32_t w1c)
{
    PMU(PMU_STATUS) = w1c & PMU_ST_W1C_ALL;
}

uint32_t pmu_cur_op(void)
{
    return PMU_ST_CUR_OP(PMU(PMU_STATUS));
}

uint32_t pmu_sleep_count(void)
{
    return PMU(PMU_SLEEP_CNT);
}

uint32_t pmu_wake_cause(void)
{
    return PMU(PMU_WAKE_CAUSE);
}
