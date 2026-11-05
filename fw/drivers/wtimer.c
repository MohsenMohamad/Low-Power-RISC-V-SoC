/* Wake timer driver (doc/SOC_REGMAP.md 0x2000_4000): AON down-counter,
 * interrupt controller source 1 (STATUS.EXPIRED, W1C). */
#include "drivers.h"

#define WT(off) REG32(WTIMER_BASE + (off))

void wtimer_start(uint32_t ticks, int periodic)
{
    WT(WT_CTRL)   = 0;
    WT(WT_STATUS) = WT_ST_EXPIRED;
    WT(WT_LOAD)   = ticks;
    WT(WT_CTRL)   = WT_CTRL_EN | (periodic ? WT_CTRL_PERIODIC : 0u);
}

void wtimer_stop(void)
{
    WT(WT_CTRL)   = 0;
    WT(WT_STATUS) = WT_ST_EXPIRED;
}

uint32_t wtimer_count(void)
{
    return WT(WT_COUNT);
}

int wtimer_expired(void)
{
    return (WT(WT_STATUS) & WT_ST_EXPIRED) != 0;
}

void wtimer_ack(void)
{
    WT(WT_STATUS) = WT_ST_EXPIRED;
}
