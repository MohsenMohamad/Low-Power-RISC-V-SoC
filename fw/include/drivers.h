/*
 * SoC peripheral drivers (doc/SOC_REGMAP.md): UART, machine timer, wake timer,
 * interrupt controller, PMU, cache maintenance (CSR mcachectl).
 *
 * Register access rules (doc/SOC_REGMAP.md, W18/W19): every driver uses
 * full-word accesses to its registers; partial writes, writes to read-only
 * registers and unmapped offsets return SLVERR, which the in-house core turns
 * into a store / load access fault.
 */
#ifndef DRIVERS_H
#define DRIVERS_H

#include <stdint.h>
#include "platform.h"

#define MUST_CHECK __attribute__((warn_unused_result))

/* ---------------- UART (drivers/uart.c) ---------------- */
void     uart_putc(char c);
int      uart_getc(void);                 /* -1 if RX FIFO empty            */
void     uart_flush(void);                /* wait until TX completely idle  */
void     uart_set_div(uint32_t div);
uint32_t uart_get_div(void);
uint32_t uart_status(void);
void     uart_set_ie(uint32_t ie);        /* UART_CTRL_RX_IE / UART_CTRL_TX_IE */
uint32_t uart_get_ie(void);

/* ---------------- machine timer (drivers/timer.c) ------- */
uint64_t timer_now(void);
void     timer_set_cmp(uint64_t t);       /* glitch-free 64-bit update      */
uint64_t timer_get_cmp(void);
void     timer_cancel(void);              /* mtimecmp = max                 */
void     timer_set_msip(int on);
uint32_t timer_get_msip(void);
void     timer_delay(uint64_t ticks);     /* busy wait                      */

/* ---------------- wake timer (drivers/wtimer.c) --------- */
void     wtimer_start(uint32_t ticks, int periodic);  /* expires ~ticks+1 clk_aon */
void     wtimer_stop(void);               /* disable and clear EXPIRED      */
uint32_t wtimer_count(void);
int      wtimer_expired(void);
void     wtimer_ack(void);                /* W1C EXPIRED                    */

/* ---------------- interrupt controller (drivers/intc.c) - */
void     intc_enable(unsigned src);
void     intc_disable(unsigned src);
uint32_t intc_enabled(void);
void     intc_set_enabled(uint32_t mask);
uint32_t intc_pending(void);              /* raw source levels              */
uint32_t intc_active(void);               /* pending & enabled              */
int      intc_claim(void);                /* lowest active source, -1 none  */

/* ---------------- PMU (drivers/pmu.c) -------------------- */
uint32_t pmu_read(uint32_t off);
void     pmu_write(uint32_t off, uint32_t v);
void     pmu_set_mode(uint32_t mode);     /* MODE + LP_EN                   */
uint32_t pmu_status(void);
void     pmu_clear_status(uint32_t w1c);
uint32_t pmu_cur_op(void);
uint32_t pmu_sleep_count(void);
uint32_t pmu_wake_cause(void);

/* ---------------- caches (drivers/cache.c, CSR mcachectl only) ----
 * D-cache clean and flush return 0, or -1 if mcachectl reported a
 * write-back error (bit 31); callers must check it. */
int      dcache_clean(void) MUST_CHECK;   /* write back all dirty lines     */
int      dcache_flush(void) MUST_CHECK;   /* clean + invalidate             */
void     icache_invalidate(void);
int      cache_sync_icache(void) MUST_CHECK;  /* after writing code: clean D, invalidate I */

/* Uncached view of a RAM object (lpsoc: the 0x3000_0000 alias). */
#if PLATFORM_HAS_SOC
#define UNCACHED(p) ((__typeof__(&(p)[0]))((uintptr_t)(p) + RAM_UNCACHED_OFFSET))
#else
#define UNCACHED(p) (&(p)[0])
#endif

#endif
