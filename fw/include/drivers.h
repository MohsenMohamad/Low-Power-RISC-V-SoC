/* SoC peripheral drivers: UART, timer, interrupt controller, PMU, caches. */
#ifndef DRIVERS_H
#define DRIVERS_H

#include <stdint.h>
#include "platform.h"

/* ---------------- UART (drivers/uart.c) ---------------- */
void     uart_putc(char c);
int      uart_getc(void);                 /* -1 if RX FIFO empty          */
void     uart_flush(void);                /* wait until TX completely idle */
void     uart_set_div(uint32_t div);
uint32_t uart_get_div(void);
uint32_t uart_status(void);
void     uart_set_ie(uint32_t ie);

/* ---------------- machine timer (drivers/timer.c) ------- */
uint64_t timer_now(void);
void     timer_set_cmp(uint64_t t);       /* glitch-free 64-bit update     */
uint64_t timer_get_cmp(void);
void     timer_cancel(void);              /* mtimecmp = max                */
void     timer_set_msip(int on);
uint32_t timer_get_msip(void);
void     timer_delay(uint64_t ticks);     /* busy wait                     */

/* ---------------- interrupt controller (drivers/intc.c) - */
void     intc_enable(unsigned src);
void     intc_disable(unsigned src);
uint32_t intc_enabled(void);
void     intc_set_enabled(uint32_t mask);
uint32_t intc_pending(void);
void     intc_soft_set(uint32_t mask);
void     intc_soft_clr(uint32_t mask);
int      intc_claim(void);                /* source index, -1 if none      */

/* ---------------- PMU (drivers/pmu.c) -------------------- */
uint32_t pmu_read(uint32_t off);
void     pmu_write(uint32_t off, uint32_t v);
int      pmu_present(void);
uint32_t pmu_rst_cause(void);
void     pmu_set_mode(uint32_t mode, int dvfs_req);
void     pmu_set_wake(uint32_t mask);
uint32_t pmu_cur_op(void);
void     pmu_clear_counters(void);
void     pmu_sw_reset(void) __attribute__((noreturn));

/* ---------------- caches (drivers/cache.c) --------------- */
void     cache_init(void);                /* invalidate both, enable both  */
void     icache_enable(int en);
void     dcache_enable(int en);
uint32_t cache_ctrl(void);
void     icache_inv_all(void);
void     dcache_inv_all(void);            /* discards dirty data!          */
void     dcache_clean_all(void);
void     dcache_flush_all(void);          /* clean + invalidate            */
void     dcache_clean_range(const void *p, uint32_t len);
void     dcache_inv_range(const void *p, uint32_t len);
void     dcache_flush_range(const void *p, uint32_t len);
void     icache_inv_range(const void *p, uint32_t len);
void     cache_sync_icache(const void *p, uint32_t len); /* after code write */
typedef struct { uint32_t dhit, dmiss, dwb, ihit, imiss; } cache_stats_t;
void     cache_stats(cache_stats_t *s);
void     cache_stats_clear(void);

/* Uncached view of a RAM address (lpsoc only). */
#if PLATFORM_HAS_SOC
#define UNCACHED(p) ((__typeof__(&(p)[0]))((uintptr_t)(p) + RAM_UNCACHED_OFFSET))
#else
#define UNCACHED(p) (&(p)[0])
#endif

#endif
