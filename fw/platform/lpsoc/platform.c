/* Platform port: low-power SoC (UART console, testbench control device). */
#include "platform_api.h"
#include "drivers.h"
#include "arch.h"

static int simctrl_present(void)
{
    return (REG32(SIMCTRL_BASE + SIMCTRL_ARG) & SIMCTRL_ARG_PRESENT) != 0;
}

void platform_init(void)
{
}

uint32_t platform_caps(void)
{
    uint32_t c = CAP_CLINT | CAP_INTC | CAP_UART | CAP_CACHE | CAP_BOOTROM;
    if (pmu_present()) c |= CAP_PMU | CAP_DVFS;
    if (simctrl_present()) c |= CAP_SIMCTRL;
    return c;
}

void platform_putc(char c)
{
    uart_putc(c);
}

int platform_getc(void)
{
    return uart_getc();
}

uint32_t platform_boot_arg(void)
{
    uint32_t a = REG32(SIMCTRL_BASE + SIMCTRL_ARG);
    if (!(a & SIMCTRL_ARG_PRESENT) || (a & SIMCTRL_ARG_MONITOR))
        return BOOTARG_MONITOR;
    return BOOTARG_AUTORUN | BOOTARG_TEST(a);
}

void platform_exit(uint32_t code)
{
    uart_flush();
    REG32(SIMCTRL_BASE + SIMCTRL_EXIT) = code;   /* ends a simulation */
    for (;;) arch_wfi();                         /* hardware: stop here */
}
