/*
 * Crash handler: dumps trace buffer, event counters, CPU cycle/instret
 * counters and the error log over the console in the fixed format of
 * doc/DEBUG_SPEC.md section 10, protected by a CRC-32 over the dump lines.
 */
#include "dbg_crash.h"
#include "drivers.h"
#include "arch.h"
#include "lib.h"

uint32_t dbg_crash_seed;
void (*dbg_crash_after)(int is_exception);

static uint32_t crc;

/* Line builder: every dump line is assembled in buf, then printed and added
 * to the running CRC (doc/DEBUG_SPEC.md section 10). */
static char     buf[512];
static unsigned pos;

static void s_(const char *t) { while (*t && pos < sizeof(buf) - 2) buf[pos++] = *t++; }
static void x_(uint32_t v)
{
    static const char hx[] = "0123456789abcdef";
    s_("0x");
    for (int i = 28; i >= 0; i -= 4) if (pos < sizeof(buf) - 2) buf[pos++] = hx[(v >> i) & 15u];
}
static void x64_(uint64_t v)
{
    static const char hx[] = "0123456789abcdef";
    s_("0x");
    for (int i = 60; i >= 0; i -= 4) if (pos < sizeof(buf) - 2) buf[pos++] = hx[(v >> i) & 15u];
}
static void u_(uint32_t v)
{
    char t[11];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) if (pos < sizeof(buf) - 2) buf[pos++] = t[--n];
}
static void kx(const char *k, uint32_t v) { s_(" "); s_(k); s_("="); x_(v); }
static void kx64(const char *k, uint64_t v) { s_(" "); s_(k); s_("="); x64_(v); }
static void begin(const char *t) { pos = 0; s_(t); }
static void end_line(void)
{
    buf[pos++] = '\n';
    buf[pos] = 0;
    crc = crc32_update(crc, buf, pos);
    puts_(buf);
}

void dbg_crash_dump(const char *reason, const trap_frame_t *f)
{
    dbg_errlog_t e;
    dbg_evcnt_t  c;
    uint64_t cyc = arch_cycles(), ins = arch_instret();

    /* freeze the trace and the counters first so the dump itself is not
     * recorded over the interesting history */
    dbg_trace_freeze();
    dbg_evcnt_ctrl(1, 1);

    crc = 0;
    puts_("\n");
    begin("### DBG-CRASH BEGIN v1"); end_line();
    begin("REASON "); s_(reason); end_line();
    begin("SEED"); s_(" "); x_(dbg_crash_seed); end_line();
    begin("CSR");
    kx("mcause", f ? f->cause : 0); kx("mepc", f ? f->epc : 0); kx("mtval", f ? f->tval : 0);
    kx("mstatus", f ? f->status : 0); kx64("mcycle", cyc); kx64("minstret", ins);
    end_line();
    dbg_errlog_read(&e);
    begin("ERRLOG");
    kx("status", e.status); kx("exc_cause", e.exc_cause); kx("exc_pc", e.exc_pc);
    kx("exc_tval", e.exc_tval); kx("exc_ts", e.exc_ts); kx("exc_cnt", e.exc_cnt);
    kx("pwr_last", e.pwr_last); kx("pwr_ts", e.pwr_ts); kx("pwr_err_last", e.pwr_err_last);
    kx("wdt_cnt", e.wdt_cnt); kx("wdt_ts", e.wdt_ts); kx("wdt_pstate", e.wdt_pstate);
    kx("sw_code", e.sw_code);
    end_line();
    dbg_evcnt_read(&c);
    begin("COUNTERS");
    kx("ic_hit", c.ic_hit); kx("ic_miss", c.ic_miss); kx("dc_hit", c.dc_hit); kx("dc_miss", c.dc_miss);
    kx("stall", c.stall); kx("wake", c.wake); kx("dvfs", c.dvfs); kx("trans", c.trans);
    kx64("t_run", c.t_state[0]); kx64("t_idle", c.t_state[1]); kx64("t_sleep", c.t_state[2]);
    kx64("t_dsleep", c.t_state[3]); kx("pstate", c.pstate);
    end_line();
    uint32_t n = dbg_trace_count();
    begin("TRACE");
    kx("status", dbg_trace_status()); s_(" count="); u_(n); s_(" wptr="); u_(dbg_trace_wptr());
    s_(" depth="); u_(dbg_trace_depth()); kx("total", dbg_trace_total());
    end_line();
    for (uint32_t k = 0; k < n; k++) {
        dbg_trace_entry_t t;
        dbg_trace_get(k, &t);
        begin("T "); u_(k); kx("pc", t.pc); kx("data", t.data); kx("ts", t.ts); kx("info", t.info);
        end_line();
    }
    begin("### DBG-CRASH END crc="); x_(crc); buf[pos++] = '\n'; buf[pos] = 0; puts_(buf);
}

static void crash_exc(trap_frame_t *f)
{
    dbg_crash_dump("exception", f);
    if (dbg_crash_after) dbg_crash_after(1);
    for (;;) arch_wfi();
}

void dbg_crash_install(void)
{
    trap_set_exc_handler(crash_exc);
}

int dbg_crash_check_boot(void)
{
    uint32_t st = dbg_errlog_status();
    const char *why;
    if (st & (ERR_ST_WDT_BITE | ERR_ST_WDT_RST)) why = "watchdog";
    else if (st & ERR_ST_PWR_ERR)               why = "pwr-err";
    else if (st & ERR_ST_EXC)                   why = "boot-sticky";
    else return 0;
    dbg_crash_dump(why, 0);
    return 1;
}
