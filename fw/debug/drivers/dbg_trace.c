/* Trace buffer driver (doc/DEBUG_SPEC.md section 5). */
#include "dbg_drv.h"

#define R(o) DBG_REG(DBG_TRACE_BASE, o)

int dbg_present(void)
{
    return DBG_REG(DBG_TRACE_BASE, DBG_ID) == DBG_ID_TRACE &&
           DBG_REG(DBG_EVCNT_BASE, DBG_ID) == DBG_ID_EVCNT &&
           DBG_REG(DBG_ERRLOG_BASE, DBG_ID) == DBG_ID_ERRLOG &&
           DBG_REG(DBG_WDT_BASE, DBG_ID) == DBG_ID_WDT;
}

void dbg_trace_setup(const dbg_trace_cfg_t *c)
{
    uint32_t f = c->ctrl_flags & (TRC_CTRL_LOG_TRAP | TRC_CTRL_LOG_PWR | TRC_CTRL_FRZ_EXC | TRC_CTRL_FRZ_ERR);
    R(TRC_CTRL)     = f;                    /* disable: config is writable */
    R(TRC_TRIG)     = (c->start_sel & 3u) | ((c->stop_sel & 3u) << 4);
    R(TRC_START_PC) = c->start_pc;
    R(TRC_STOP_PC)  = c->stop_pc;
    R(TRC_PC_MASK)  = c->pc_mask;
    R(TRC_CTRL)     = f | TRC_CTRL_CLEAR | TRC_CTRL_EN;
}

void dbg_trace_enable(int en)
{
    uint32_t v = R(TRC_CTRL) & ~(TRC_CTRL_EN | TRC_CTRL_CLEAR | TRC_CTRL_FREEZE);
    R(TRC_CTRL) = v | (en ? TRC_CTRL_EN : 0u);
}

void dbg_trace_freeze(void)
{
    uint32_t v = R(TRC_CTRL) & ~(TRC_CTRL_CLEAR | TRC_CTRL_FREEZE);
    R(TRC_CTRL) = v | TRC_CTRL_FREEZE;
}

uint32_t dbg_trace_status(void) { return R(TRC_STATUS); }
uint32_t dbg_trace_count(void)  { return R(TRC_COUNT); }
uint32_t dbg_trace_total(void)  { return R(TRC_TOTAL); }
uint32_t dbg_trace_depth(void)  { return R(TRC_DEPTH); }
uint32_t dbg_trace_wptr(void)   { return R(TRC_WPTR); }

void dbg_trace_get(uint32_t k, dbg_trace_entry_t *e)
{
    uint32_t depth = R(TRC_DEPTH);
    uint32_t oldest = (R(TRC_STATUS) & TRC_ST_WRAPPED) ? R(TRC_WPTR) : 0u;
    uint32_t i = (oldest + k) & (depth - 1u);
    e->pc   = R(TRC_ENTRY(i) + 0u);
    e->data = R(TRC_ENTRY(i) + 4u);
    e->ts   = R(TRC_ENTRY(i) + 8u);
    e->info = R(TRC_ENTRY(i) + 12u);
}
