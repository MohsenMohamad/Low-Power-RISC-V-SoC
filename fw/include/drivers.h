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
void     pmu_set_wake_mask(uint32_t mask);   /* WAKE_MEIP | WAKE_MTIP | WAKE_MSIP */
uint32_t pmu_wake_mask(void);
uint32_t pmu_idle_count(void);

/* ---------------- caches (drivers/cache.c, CSR mcachectl only) ----
 * D-cache clean and flush return 0, or -1 if mcachectl reported a
 * write-back error (bit 31); callers must check it. */
int      dcache_clean(void) MUST_CHECK;   /* write back all dirty lines     */
int      dcache_flush(void) MUST_CHECK;   /* clean + invalidate             */
void     icache_invalidate(void);
int      cache_sync_icache(void) MUST_CHECK;  /* after writing code: clean D, invalidate I */

/* ---------------- cache statistics (drivers/dbg.c) ----------------
 * doc/SPEC.md: cache statistics come from the debug event counters. */
typedef struct { uint32_t ic_hit, ic_miss, dc_hit, dc_miss; } cache_stats_t;
void     cache_stats(cache_stats_t *s);   /* lags the CPU by 2-3 clk_aon cycles */

/* ---------------- debug blocks (drivers/dbg.c, doc/DEBUG_SPEC.md) ---------------- */
int      dbg_present(void);               /* all four blocks answer with their ID */

typedef struct {
    uint32_t start_sel, stop_sel;         /* TRC_TRIG_*                   */
    uint32_t start_pc, stop_pc, pc_mask;
    uint32_t ctrl_flags;                  /* TRC_CTRL_LOG_* / FRZ_*       */
} dbg_trace_cfg_t;
typedef struct { uint32_t pc, data, ts, info; } dbg_trace_entry_t;
void     dbg_trace_setup(const dbg_trace_cfg_t *cfg);   /* disable, configure, clear, enable */
void     dbg_trace_enable(int en);
void     dbg_trace_freeze(void);
uint32_t dbg_trace_status(void);
uint32_t dbg_trace_count(void);
uint32_t dbg_trace_total(void);
uint32_t dbg_trace_depth(void);
uint32_t dbg_trace_wptr(void);
void     dbg_trace_get(uint32_t k, dbg_trace_entry_t *e);   /* k = 0: oldest entry */

typedef struct {
    uint32_t ic_hit, ic_miss, dc_hit, dc_miss, stall;
    uint32_t wake, dvfs, trans;
    uint64_t t_state[4];                  /* RUN, IDLE, SLEEP, DEEP_SLEEP (clk_aon cycles) */
    uint32_t pstate;                      /* [1:0] power state, [5:4] OP */
} dbg_evcnt_t;
int      dbg_evcnt_clear(void) MUST_CHECK;   /* 0, or -1 if the clear did not complete */
void     dbg_evcnt_ctrl(int freeze, int freeze_on_err);
void     dbg_evcnt_read(dbg_evcnt_t *c);
uint32_t dbg_evcnt_get(uint32_t off);     /* one 32-bit counter (EVC_*)   */
void     dbg_evcnt_settle(void);          /* wait until the clk_cpu counters have reached clk_aon */

typedef struct {
    uint32_t status, exc_cause, exc_pc, exc_tval, exc_ts, exc_cnt;
    uint32_t pwr_last, pwr_ts, pwr_err_last, wdt_cnt, wdt_ts, wdt_pstate, sw_code;
} dbg_errlog_t;
uint32_t dbg_errlog_status(void);
void     dbg_errlog_clear(uint32_t mask);
void     dbg_errlog_sw_error(uint32_t code);
void     dbg_errlog_read(dbg_errlog_t *e);
void     dbg_errlog_irq_en(uint32_t mask);
uint32_t dbg_errlog_get(uint32_t off);

void     dbg_wdt_start(uint32_t timeout, uint32_t bark, uint32_t flags);
void     dbg_wdt_stop(void);
void     dbg_wdt_kick(void);
uint32_t dbg_wdt_status(void);
void     dbg_wdt_clear_status(uint32_t w1c);
uint32_t dbg_wdt_count(void);
uint32_t dbg_wdt_rst_cnt(void);

/* Uncached view of a RAM object (lpsoc: the 0x3000_0000 alias). */
#if PLATFORM_HAS_SOC
#define UNCACHED(p) ((__typeof__(&(p)[0]))((uintptr_t)(p) + RAM_UNCACHED_OFFSET))
#else
#define UNCACHED(p) (&(p)[0])
#endif

#endif
