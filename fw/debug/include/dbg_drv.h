/* Drivers for the debug blocks: trace buffer, event counters, error log,
 * watchdog (fw/debug/drivers). Only 32-bit accesses are used. */
#ifndef DBG_DRV_H
#define DBG_DRV_H

#include <stdint.h>
#include "dbg_regs.h"

/* 1 if all four blocks answer with their ID at DBG_BASE. */
int dbg_present(void);

/* ---- trace buffer ---- */
typedef struct {
    uint32_t start_sel, stop_sel;   /* TRC_TRIG_*                       */
    uint32_t start_pc, stop_pc, pc_mask;
    uint32_t ctrl_flags;            /* TRC_CTRL_LOG_* / FRZ_*           */
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
/* k = 0 is the oldest valid entry. */
void     dbg_trace_get(uint32_t k, dbg_trace_entry_t *e);

/* ---- event counters ---- */
typedef struct {
    uint32_t ic_hit, ic_miss, dc_hit, dc_miss, stall;
    uint32_t wake, dvfs, trans;
    uint64_t t_state[4];            /* RUN, IDLE, SLEEP, DEEP_SLEEP     */
    uint32_t pstate;
} dbg_evcnt_t;

void dbg_evcnt_clear(void);
void dbg_evcnt_ctrl(int freeze, int freeze_on_err);
void dbg_evcnt_read(dbg_evcnt_t *c);

/* ---- error log ---- */
typedef struct {
    uint32_t status, exc_cause, exc_pc, exc_tval, exc_ts, exc_cnt;
    uint32_t pwr_last, pwr_ts, pwr_err_last, wdt_cnt, wdt_ts, wdt_pstate, sw_code;
} dbg_errlog_t;

uint32_t dbg_errlog_status(void);
void     dbg_errlog_clear(uint32_t mask);
void     dbg_errlog_sw_error(uint32_t code);
void     dbg_errlog_read(dbg_errlog_t *e);

/* ---- watchdog ---- */
void     dbg_wdt_start(uint32_t timeout, uint32_t bark, uint32_t flags);
void     dbg_wdt_stop(void);
void     dbg_wdt_kick(void);
uint32_t dbg_wdt_status(void);
uint32_t dbg_wdt_count(void);
uint32_t dbg_wdt_rst_cnt(void);

#endif
