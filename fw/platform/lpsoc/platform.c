/* Platform port: the low-power SoC. Console on the UART; boot argument from
 * the host mailbox in RAM (doc/BOOT_ABI.md); end of run reported on the UART
 * (doc/BOOT_ABI.md "Test completion"). */
#include "platform_api.h"
#include "drivers.h"
#include "handoff.h"
#include "arch.h"
#include "lib.h"

void platform_init(void)
{
}

uint32_t platform_caps(void)
{
    return CAP_CLINT | CAP_INTC | CAP_UART | CAP_PMU | CAP_CACHE | CAP_DVFS |
           CAP_BOOTROM | CAP_WTIMER;
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
    /* written by the host before the CPU starts: read it through the
     * uncached alias (it never went through this CPU's D-cache) */
    volatile hostbox_t *hb = (volatile hostbox_t *)(HOSTBOX_ADDR + RAM_UNCACHED_OFFSET);
    if (hb->magic != HOSTBOX_MAGIC) return BOOTARG_MONITOR;
    return hb->boot_arg;
}

uint32_t platform_host_arg(unsigned i)
{
    volatile hostbox_t *hb = (volatile hostbox_t *)(HOSTBOX_ADDR + RAM_UNCACHED_OFFSET);
    if (hb->magic != HOSTBOX_MAGIC || i >= 3) return 0;
    return hb->arg[i];
}

void platform_exit(uint32_t code)
{
    HANDOFF->signature = code;
    if (code == 0) puts_("PASS\n");
    else printf_("FAIL 0x%08x\n", (unsigned)code);
    uart_flush();
    (void)arch_irq_save();
    (void)arch_irq_mask_save(0);
    pmu_set_wake_mask(0);
    pmu_set_mode(PMU_MODE_IDLE);
    for (;;) arch_wfi();        /* no wake source: stays clock gated */
}
