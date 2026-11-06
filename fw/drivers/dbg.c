/* Debug-block drivers (doc/DEBUG_SPEC.md): trace buffer, event counters,
 * error log, watchdog, and the cache statistics, which come from the event
 * counters (doc/SPEC.md "Cache maintenance"). Full-word accesses only. */
#include "drivers.h"

#if PLATFORM_HAS_SOC
#define TRC(o) REG32(DBG_TRACE_BASE + (o))
#define EVC(o) REG32(DBG_EVCNT_BASE + (o))
#define ERR(o) REG32(DBG_ERRLOG_BASE + (o))
#define WDT(o) REG32(DBG_WDT_BASE + (o))

int dbg_present(void)
{
    return TRC(DBG_ID) == DBG_ID_TRACE && EVC(DBG_ID) == DBG_ID_EVCNT &&
           ERR(DBG_ID) == DBG_ID_ERRLOG && WDT(DBG_ID) == DBG_ID_WDT;
}

/* ---------------- trace buffer ---------------- */
void dbg_trace_setup(const dbg_trace_cfg_t *c)
{
    uint32_t f = c->ctrl_flags & (TRC_CTRL_LOG_TRAP | TRC_CTRL_LOG_PWR | TRC_CTRL_FRZ_EXC | TRC_CTRL_FRZ_ERR);
    TRC(TRC_CTRL)     = f;                  /* disabled: the configuration is writable */
    TRC(TRC_TRIG)     = (c->start_sel & 3u) | ((c->stop_sel & 3u) << 4);
    TRC(TRC_START_PC) = c->start_pc;
    TRC(TRC_STOP_PC)  = c->stop_pc;
    TRC(TRC_PC_MASK)  = c->pc_mask;
    TRC(TRC_CTRL)     = f | TRC_CTRL_CLEAR | TRC_CTRL_EN;
    while (TRC(TRC_STATUS) & TRC_ST_CLR_PEND) ;     /* clk_cpu runs: completes */
}

void dbg_trace_enable(int en)
{
    uint32_t v = TRC(TRC_CTRL) & ~(TRC_CTRL_EN | TRC_CTRL_CLEAR | TRC_CTRL_FREEZE);
    TRC(TRC_CTRL) = v | (en ? TRC_CTRL_EN : 0u);
}

void dbg_trace_freeze(void)
{
    uint32_t v = TRC(TRC_CTRL) & ~(TRC_CTRL_CLEAR | TRC_CTRL_FREEZE);
    TRC(TRC_CTRL) = v | TRC_CTRL_FREEZE;
}

uint32_t dbg_trace_status(void) { return TRC(TRC_STATUS); }
uint32_t dbg_trace_count(void)  { return TRC(TRC_COUNT); }
uint32_t dbg_trace_total(void)  { return TRC(TRC_TOTAL); }
uint32_t dbg_trace_depth(void)  { return TRC(TRC_DEPTH); }
uint32_t dbg_trace_wptr(void)   { return TRC(TRC_WPTR); }

void dbg_trace_get(uint32_t k, dbg_trace_entry_t *e)
{
    uint32_t depth  = TRC(TRC_DEPTH);
    uint32_t oldest = (TRC(TRC_STATUS) & TRC_ST_WRAPPED) ? TRC(TRC_WPTR) : 0u;
    uint32_t i = (oldest + k) & (depth - 1u);
    e->pc   = TRC(TRC_ENTRY(i) + 0u);
    e->data = TRC(TRC_ENTRY(i) + 4u);
    e->ts   = TRC(TRC_ENTRY(i) + 8u);
    e->info = TRC(TRC_ENTRY(i) + 12u);
}

/* ---------------- event counters ---------------- */
static uint32_t evc_ctrl;

int dbg_evcnt_clear(void)
{
    EVC(EVC_CTRL) = evc_ctrl | EVC_CTRL_CLEAR;
    /* the clear is applied in clk_cpu, which runs while this code runs */
    for (uint32_t i = 0; i < 1000u; i++)
        if (!(EVC(EVC_STATUS) & EVC_ST_CLR_PEND)) return 0;
    return -1;
}

void dbg_evcnt_ctrl(int freeze, int freeze_on_err)
{
    evc_ctrl = (freeze ? EVC_CTRL_FREEZE : 0u) | (freeze_on_err ? EVC_CTRL_FRZ_ERR : 0u);
    EVC(EVC_CTRL) = evc_ctrl;
}

uint32_t dbg_evcnt_get(uint32_t off) { return EVC(off); }

/* The clk_cpu counters reach the clk_aon registers 2-3 clk_aon cycles late:
 * a few uncached reads (each a CDC round trip, several clk_aon cycles) cover
 * that. No cacheable access is made, so the D-cache counters do not move. */
void dbg_evcnt_settle(void)
{
    for (int i = 0; i < 4; i++) (void)EVC(DBG_ID);
}

void dbg_evcnt_read(dbg_evcnt_t *c)
{
    c->ic_hit  = EVC(EVC_IC_HIT);
    c->ic_miss = EVC(EVC_IC_MISS);
    c->dc_hit  = EVC(EVC_DC_HIT);
    c->dc_miss = EVC(EVC_DC_MISS);
    c->stall   = EVC(EVC_STALL);
    c->wake    = EVC(EVC_WAKE);
    c->dvfs    = EVC(EVC_DVFS);
    c->trans   = EVC(EVC_TRANS);
    for (unsigned s = 0; s < 4; s++) {
        uint32_t lo = EVC(EVC_T_LO(s));     /* LO first: latches HI */
        uint32_t hi = EVC(EVC_T_HI(s));
        c->t_state[s] = ((uint64_t)hi << 32) | lo;
    }
    c->pstate = EVC(EVC_PSTATE);
}

void cache_stats(cache_stats_t *s)
{
    s->ic_hit  = EVC(EVC_IC_HIT);
    s->ic_miss = EVC(EVC_IC_MISS);
    s->dc_hit  = EVC(EVC_DC_HIT);
    s->dc_miss = EVC(EVC_DC_MISS);
}

/* ---------------- error log ---------------- */
uint32_t dbg_errlog_status(void)          { return ERR(ERR_STATUS); }
void     dbg_errlog_clear(uint32_t mask)  { ERR(ERR_STATUS) = mask; }
void     dbg_errlog_sw_error(uint32_t c)  { ERR(ERR_SW_ERR) = c; }
void     dbg_errlog_irq_en(uint32_t mask) { ERR(ERR_IRQ_EN) = mask; }
uint32_t dbg_errlog_get(uint32_t off)     { return ERR(off); }

void dbg_errlog_read(dbg_errlog_t *e)
{
    e->status       = ERR(ERR_STATUS);
    e->exc_cause    = ERR(ERR_EXC_CAUSE);
    e->exc_pc       = ERR(ERR_EXC_PC);
    e->exc_tval     = ERR(ERR_EXC_TVAL);
    e->exc_ts       = ERR(ERR_EXC_TS);
    e->exc_cnt      = ERR(ERR_EXC_CNT);
    e->pwr_last     = ERR(ERR_PWR_LAST);
    e->pwr_ts       = ERR(ERR_PWR_TS);
    e->pwr_err_last = ERR(ERR_PWR_ERR_LAST);
    e->wdt_cnt      = ERR(ERR_WDT_CNT);
    e->wdt_ts       = ERR(ERR_WDT_TS);
    e->wdt_pstate   = ERR(ERR_WDT_PSTATE);
    e->sw_code      = ERR(ERR_SW_CODE);
}

/* ---------------- watchdog ---------------- */
void dbg_wdt_start(uint32_t timeout, uint32_t bark, uint32_t flags)
{
    WDT(WDT_CTRL)   = 0;                    /* disabled while reconfiguring */
    WDT(WDT_LOAD)   = timeout;
    WDT(WDT_BARK)   = bark;
    WDT(WDT_STATUS) = WDT_ST_BARK | WDT_ST_BITE | WDT_ST_BAD_KICK;
    WDT(WDT_CTRL)   = (flags & ~WDT_CTRL_LOCK) | WDT_CTRL_EN;   /* EN rise reloads COUNT */
    if (flags & WDT_CTRL_LOCK) WDT(WDT_CTRL) = flags | WDT_CTRL_EN;
}

void     dbg_wdt_stop(void)                 { WDT(WDT_CTRL) = WDT(WDT_CTRL) & ~WDT_CTRL_EN; }
void     dbg_wdt_kick(void)                 { WDT(WDT_KICK) = WDT_KICK_KEY; }
uint32_t dbg_wdt_status(void)               { return WDT(WDT_STATUS); }
void     dbg_wdt_clear_status(uint32_t w1c) { WDT(WDT_STATUS) = w1c; }
uint32_t dbg_wdt_count(void)                { return WDT(WDT_COUNT); }
uint32_t dbg_wdt_rst_cnt(void)              { return WDT(WDT_RST_CNT); }
#endif
