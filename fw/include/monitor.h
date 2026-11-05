#ifndef MONITOR_H
#define MONITOR_H

#include <stdint.h>

#define MON_PROMPT      "mon> "
#define MON_WAKE_PROMPT "zzz> "     /* printed before sleeping until UART input */

typedef struct {
    const char *name;
    const char *args;
    const char *help;
    int (*fn)(int argc, char **argv);       /* 0 = OK, otherwise error   */
} mon_cmd_t;

/* Interactive command loop over the console. Never returns. */
void monitor_run(const mon_cmd_t *extra, unsigned n_extra) __attribute__((noreturn));
/* Resolve "0x...", decimal or a symbolic register name ("pmu.status"). */
int  mon_parse_addr(const char *s, uint32_t *addr);

#endif
