/* Crash handler and fixed-format UART dump (doc/DEBUG_SPEC.md section 10). */
#ifndef DBG_CRASH_H
#define DBG_CRASH_H

#include <stdint.h>
#include "trap.h"

/* Seed printed in every dump (set by the application). */
extern uint32_t dbg_crash_seed;

/* Print the dump. f may be NULL (no trap frame: watchdog / post-mortem). */
void dbg_crash_dump(const char *reason, const trap_frame_t *f);

/* Install the crash handler for synchronous exceptions. */
void dbg_crash_install(void);

/* At boot: if the error log holds a sticky watchdog / power error from
 * before the reset, dump it (reason "watchdog" / "pwr-err" / "boot-sticky")
 * and return 1. */
int dbg_crash_check_boot(void);

/* Called after a dump; the application decides (exit / monitor). */
extern void (*dbg_crash_after)(int is_exception);

#endif
