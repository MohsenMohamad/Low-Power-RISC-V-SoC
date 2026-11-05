/* Machine timer driver (CLINT register layout; also the SoC wake timer). */
#include "drivers.h"

#define CLINT(off) REG32(CLINT_BASE + (off))

uint64_t timer_now(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = CLINT(CLINT_MTIME + 4);
        lo  = CLINT(CLINT_MTIME);
        hi2 = CLINT(CLINT_MTIME + 4);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

void timer_set_cmp(uint64_t t)
{
    /* never let the intermediate value be smaller than both old and new */
    CLINT(CLINT_MTIMECMP + 4) = 0xFFFFFFFFu;
    CLINT(CLINT_MTIMECMP)     = (uint32_t)t;
    CLINT(CLINT_MTIMECMP + 4) = (uint32_t)(t >> 32);
}

uint64_t timer_get_cmp(void)
{
    return ((uint64_t)CLINT(CLINT_MTIMECMP + 4) << 32) | CLINT(CLINT_MTIMECMP);
}

void timer_cancel(void)
{
    CLINT(CLINT_MTIMECMP + 4) = 0xFFFFFFFFu;
    CLINT(CLINT_MTIMECMP)     = 0xFFFFFFFFu;
}

void timer_set_msip(int on)
{
    CLINT(CLINT_MSIP) = on ? 1u : 0u;
}

uint32_t timer_get_msip(void)
{
    return CLINT(CLINT_MSIP) & 1u;
}

void timer_delay(uint64_t ticks)
{
    uint64_t end = timer_now() + ticks;
    while (timer_now() < end) ;
}
