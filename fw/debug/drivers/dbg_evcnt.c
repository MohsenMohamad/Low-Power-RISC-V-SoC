/* Event counter driver (doc/DEBUG_SPEC.md section 6). */
#include "dbg_drv.h"

#define R(o) DBG_REG(DBG_EVCNT_BASE, o)

static uint32_t ctrl_shadow;

void dbg_evcnt_clear(void)
{
    R(EVC_CTRL) = ctrl_shadow | EVC_CTRL_CLEAR;
    while (R(EVC_STATUS) & 2u) ;            /* CLR_PEND (clk_cpu is running) */
}

void dbg_evcnt_ctrl(int freeze, int freeze_on_err)
{
    ctrl_shadow = (freeze ? EVC_CTRL_FREEZE : 0u) | (freeze_on_err ? EVC_CTRL_FRZ_ERR : 0u);
    R(EVC_CTRL) = ctrl_shadow;
}

void dbg_evcnt_read(dbg_evcnt_t *c)
{
    c->ic_hit  = R(EVC_IC_HIT);
    c->ic_miss = R(EVC_IC_MISS);
    c->dc_hit  = R(EVC_DC_HIT);
    c->dc_miss = R(EVC_DC_MISS);
    c->stall   = R(EVC_STALL);
    c->wake    = R(EVC_WAKE);
    c->dvfs    = R(EVC_DVFS);
    c->trans   = R(EVC_TRANS);
    for (unsigned s = 0; s < 4; s++) {
        uint32_t lo = R(EVC_T_LO(s));       /* LO first: latches HI */
        uint32_t hi = R(EVC_T_HI(s));
        c->t_state[s] = ((uint64_t)hi << 32) | lo;
    }
    c->pstate = R(EVC_PSTATE);
}
