/* Error / crash log driver (doc/DEBUG_SPEC.md section 7). */
#include "dbg_drv.h"

#define R(o) DBG_REG(DBG_ERRLOG_BASE, o)

uint32_t dbg_errlog_status(void)          { return R(ERR_STATUS); }
void     dbg_errlog_clear(uint32_t mask)  { R(ERR_STATUS) = mask; }
void     dbg_errlog_sw_error(uint32_t c)  { R(ERR_SW_ERR) = c; }

void dbg_errlog_read(dbg_errlog_t *e)
{
    e->status       = R(ERR_STATUS);
    e->exc_cause    = R(ERR_EXC_CAUSE);
    e->exc_pc       = R(ERR_EXC_PC);
    e->exc_tval     = R(ERR_EXC_TVAL);
    e->exc_ts       = R(ERR_EXC_TS);
    e->exc_cnt      = R(ERR_EXC_CNT);
    e->pwr_last     = R(ERR_PWR_LAST);
    e->pwr_ts       = R(ERR_PWR_TS);
    e->pwr_err_last = R(ERR_PWR_ERR_LAST);
    e->wdt_cnt      = R(ERR_WDT_CNT);
    e->wdt_ts       = R(ERR_WDT_TS);
    e->wdt_pstate   = R(ERR_WDT_PSTATE);
    e->sw_code      = R(ERR_SW_CODE);
}
