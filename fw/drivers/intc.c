/* Interrupt controller driver (doc/SOC_REGMAP.md: PENDING RO, ENABLE RW,
 * ACTIVE RO). Sources are level-sensitive and cleared at their origin; there
 * is no claim register: intc_claim() picks the lowest active source. */
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

uint32_t intc_active(void)
{
    return INTC(INTC_ACTIVE);
}

int intc_claim(void)
{
    uint32_t a = INTC(INTC_ACTIVE);
    for (int i = 0; i < 8; i++)
        if (a & (1u << i)) return i;
    return -1;
}
