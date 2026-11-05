/* Watchdog driver (doc/DEBUG_SPEC.md section 8). */
#include "dbg_drv.h"

#define R(o) DBG_REG(DBG_WDT_BASE, o)

void dbg_wdt_start(uint32_t timeout, uint32_t bark, uint32_t flags)
{
    R(WDT_CTRL) = 0;                       /* disable while reconfiguring */
    R(WDT_LOAD) = timeout;
    R(WDT_BARK) = bark;
    R(WDT_STATUS) = 0xFu;                  /* clear BARK / BITE / BAD_KICK */
    R(WDT_CTRL) = (flags & ~WDT_CTRL_LOCK) | WDT_CTRL_EN;   /* EN rise reloads */
    if (flags & WDT_CTRL_LOCK) R(WDT_CTRL) = flags | WDT_CTRL_EN;
}

void     dbg_wdt_stop(void)    { R(WDT_CTRL) = R(WDT_CTRL) & ~WDT_CTRL_EN; }
void     dbg_wdt_kick(void)    { R(WDT_KICK) = WDT_KICK_KEY; }
uint32_t dbg_wdt_status(void)  { return R(WDT_STATUS); }
uint32_t dbg_wdt_count(void)   { return R(WDT_COUNT); }
uint32_t dbg_wdt_rst_cnt(void) { return R(WDT_RST_CNT); }
