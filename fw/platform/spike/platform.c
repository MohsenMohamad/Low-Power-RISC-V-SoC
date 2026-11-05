/* Platform port: Spike (HTIF console and exit, CLINT timer). */
#include "platform_api.h"

volatile uint64_t tohost   __attribute__((section(".tohost"), aligned(64)));
volatile uint64_t fromhost __attribute__((section(".tohost"), aligned(64)));

static void htif_cmd(uint64_t dev, uint64_t cmd, uint64_t payload, int wait_resp)
{
    while (tohost) ;
    tohost = (dev << 56) | (cmd << 48) | payload;
    if (wait_resp) {
        while (!fromhost) ;
        fromhost = 0;
    }
}

void platform_init(void)
{
}

uint32_t platform_caps(void)
{
    return CAP_CLINT;
}

void platform_putc(char c)
{
    htif_cmd(1, 1, (uint8_t)c, 1);     /* bcd device: putchar */
}

int platform_getc(void)
{
    return -1;
}

uint32_t platform_boot_arg(void)
{
#ifdef SPIKE_TEST
    return BOOTARG_AUTORUN | BOOTARG_TEST(SPIKE_TEST);
#else
    return BOOTARG_AUTORUN | BOOTARG_ALL;
#endif
}

void platform_exit(uint32_t code)
{
    /* HTIF exit status is (tohost >> 1); keep it non-zero for any failure */
    uint64_t st = code ? 1 : 0;
    for (;;) htif_cmd(0, 0, (st << 1) | 1, 0);
}
