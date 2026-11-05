/* Services every platform port provides (platform/<name>/platform.c). */
#ifndef PLATFORM_API_H
#define PLATFORM_API_H

#include <stdint.h>

/* Platform capability bits (CPU capability bits are in arch.h). */
#define CAP_CLINT       (1u << 8)   /* machine timer: mtime / mtimecmp / msip */
#define CAP_INTC        (1u << 9)   /* SoC interrupt controller           */
#define CAP_UART        (1u << 10)  /* SoC UART                           */
#define CAP_PMU         (1u << 11)  /* PMU: IDLE / SLEEP / DEEP_SLEEP     */
#define CAP_CACHE       (1u << 12)  /* I$/D$, maintenance through mcachectl */
#define CAP_DVFS        (1u << 13)  /* operating-point changes            */
#define CAP_BOOTROM     (1u << 14)  /* boot ROM resume path               */
#define CAP_WTIMER      (1u << 15)  /* AON wake timer (intc source 1)     */

/* Boot argument (platform_boot_arg) */
/* Boot argument: from the host mailbox (lpsoc, doc/BOOT_ABI.md) or built in
 * (Spike). Without a valid argument the application starts the monitor. */
#define BOOTARG_AUTORUN (1u << 31)  /* run tests non-interactively        */
#define BOOTARG_MONITOR (1u << 30)  /* start the monitor                  */
#define BOOTARG_TEST(a) ((a) & 0xFFFFu)
#define BOOTARG_ALL     0xFFFFu

void     platform_init(void);
uint32_t platform_caps(void);
void     platform_putc(char c);
int      platform_getc(void);              /* -1 if no character        */
uint32_t platform_boot_arg(void);
/* End of run: prints "PASS" (code 0) or "FAIL 0x<code>" as the last console
 * line (lpsoc: the testbench completion ABI) and stops. */
void     platform_exit(uint32_t code) __attribute__((noreturn));

#endif
