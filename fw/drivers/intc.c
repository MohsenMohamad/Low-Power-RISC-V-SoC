/* Interrupt controller driver. */
#include "drivers.h"

#define INTC(off) REG32(INTC_BASE + (off))

void intc_enable(unsigned src)
{
    INTC(INTC_ENABLE) = INTC(INTC_ENABLE) | (1u << src);
}

void intc_disable(unsigned src)
{
    INTC(INTC_ENABLE) = INTC(INTC_ENABLE) & ~(1u << src);
}

uint32_t intc_enabled(void)
{
    return INTC(INTC_ENABLE);
}

void intc_set_enabled(uint32_t mask)
{
    INTC(INTC_ENABLE) = mask;
}

uint32_t intc_pending(void)
{
    return INTC(INTC_PENDING);
}

void intc_soft_set(uint32_t mask)
{
    INTC(INTC_SOFT_SET) = mask;
}

void intc_soft_clr(uint32_t mask)
{
    INTC(INTC_SOFT_CLR) = mask;
}

int intc_claim(void)
{
    return (int)INTC(INTC_CLAIM) - 1;
}
