/* Machine timer driver: mtime / mtimecmp / msip. Register offsets come from
 * the platform (lpsoc: doc/SOC_REGMAP.md layout; Spike: CLINT layout). */
#include "drivers.h"

#define TMR(off) REG32(TIMER_BASE + (off))

uint64_t timer_now(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = TMR(TIMER_MTIME + 4);
        lo  = TMR(TIMER_MTIME);
        hi2 = TMR(TIMER_MTIME + 4);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

void timer_set_cmp(uint64_t t)
{
    /* no spurious interrupt: high word to all-ones first (doc/SOC_REGMAP.md) */
    TMR(TIMER_MTIMECMP + 4) = 0xFFFFFFFFu;
    TMR(TIMER_MTIMECMP)     = (uint32_t)t;
    TMR(TIMER_MTIMECMP + 4) = (uint32_t)(t >> 32);
}

uint64_t timer_get_cmp(void)
{
    return ((uint64_t)TMR(TIMER_MTIMECMP + 4) << 32) | TMR(TIMER_MTIMECMP);
}

void timer_cancel(void)
{
    TMR(TIMER_MTIMECMP + 4) = 0xFFFFFFFFu;
    TMR(TIMER_MTIMECMP)     = 0xFFFFFFFFu;
}

void timer_set_msip(int on)
{
    TMR(TIMER_MSIP) = on ? 1u : 0u;
}

uint32_t timer_get_msip(void)
{
    return TMR(TIMER_MSIP) & 1u;
}

void timer_delay(uint64_t ticks)
{
    uint64_t end = timer_now() + ticks;
    while (timer_now() < end) ;
}
