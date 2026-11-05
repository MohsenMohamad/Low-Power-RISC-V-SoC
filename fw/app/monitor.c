/*
 * UART bring-up monitor (built into the boot ROM fallback and the app).
 *
 *   help                      list commands
 *   peek <addr|reg> [n]       read n words (default 1)
 *   poke <addr|reg> <value>   write one word (cached RAM: D-cache cleaned)
 *   regs <block>              dump a register block (uart intc pmu timer
 *                             wtimer handoff)
 *   go <addr>                 clean D$, invalidate I$, jump to address
 *
 * Accesses that trap (SLVERR -> access fault on the in-house core: unmapped
 * address or offset, write to a read-only register) are caught and reported
 * as "ERR fault" instead of crashing the monitor.
 * Output is line oriented so that it can be checked by scripts.
 */
#include "monitor.h"
#include "lib.h"
#include "trap.h"
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"

typedef struct { const char *name; uint32_t off; } reg_t;
typedef struct { const char *name; uint32_t base; const reg_t *regs; unsigned n; } blk_t;

static const reg_t uart_regs[] = {
    {"txdata", UART_TXDATA}, {"rxdata", UART_RXDATA}, {"status", UART_STATUS}, {"ctrl", UART_CTRL},
};
static const reg_t intc_regs[] = {
    {"pending", INTC_PENDING}, {"enable", INTC_ENABLE}, {"active", INTC_ACTIVE},
};
static const reg_t pmu_regs[] = {
    {"ctrl", PMU_CTRL}, {"status", PMU_STATUS}, {"dvfs", PMU_DVFS}, {"irq_en", PMU_IRQ_EN},
    {"scratch0", PMU_SCRATCH0}, {"scratch1", PMU_SCRATCH1}, {"wake_cause", PMU_WAKE_CAUSE},
    {"sleep_cnt", PMU_SLEEP_CNT}, {"vsel", PMU_VSEL}, {"wake_mask", PMU_WAKE_MASK},
    {"idle_cnt", PMU_IDLE_CNT},
};
static const reg_t timer_regs[] = {
    {"mtime", TIMER_MTIME}, {"mtimeh", TIMER_MTIME + 4}, {"mtimecmp", TIMER_MTIMECMP},
    {"mtimecmph", TIMER_MTIMECMP + 4}, {"msip", TIMER_MSIP},
};
static const reg_t wtimer_regs[] = {
    {"ctrl", WT_CTRL}, {"load", WT_LOAD}, {"count", WT_COUNT}, {"status", WT_STATUS},
};
static const reg_t handoff_regs[] = {
    {"rom_version", 0x00}, {"boot_status", 0x04}, {"rst_cause", 0x08}, {"boot_reason", 0x0C},
    {"pmu_status", 0x10}, {"cold_boots", 0x14}, {"resumes", 0x18}, {"bad_resumes", 0x1C},
    {"signature", 0x20}, {"ctx_magic", 0x40}, {"ctx_crc", 0x44},
};

static const blk_t blocks[] = {
    {"uart",    UART_BASE,    uart_regs,    ARRAY_SIZE(uart_regs)},
    {"intc",    INTC_BASE,    intc_regs,    ARRAY_SIZE(intc_regs)},
    {"pmu",     PMU_BASE,     pmu_regs,     ARRAY_SIZE(pmu_regs)},
    {"timer",   TIMER_BASE,   timer_regs,   ARRAY_SIZE(timer_regs)},
    {"wtimer",  WTIMER_BASE,  wtimer_regs,  ARRAY_SIZE(wtimer_regs)},
    {"handoff", HANDOFF_ADDR, handoff_regs, ARRAY_SIZE(handoff_regs)},
};

static const blk_t *find_block(const char *name, size_t len)
{
    for (unsigned i = 0; i < ARRAY_SIZE(blocks); i++)
        if (strlen(blocks[i].name) == len && !strncmp(blocks[i].name, name, len))
            return &blocks[i];
    return 0;
}

int mon_parse_addr(const char *s, uint32_t *addr)
{
    if (!parse_u32(s, addr)) return 0;
    const char *dot = s;
    while (*dot && *dot != '.') dot++;
    if (!*dot) return -1;
    const blk_t *b = find_block(s, (size_t)(dot - s));
    if (!b) return -1;
    for (unsigned i = 0; i < b->n; i++)
        if (!strcmp(b->regs[i].name, dot + 1)) {
            *addr = b->base + b->regs[i].off;
            return 0;
        }
    return -1;
}

/* ---- fault-tolerant accesses ---- */
static volatile int mon_fault;

static void mon_exc(trap_frame_t *f)
{
    mon_fault = 1;
    f->epc += 4;
}

static int safe_read(uint32_t a, uint32_t *v)
{
    trap_handler_t old = trap_set_exc_handler(mon_exc);
    mon_fault = 0;
    uint32_t x = REG32(a);
    trap_set_exc_handler(old);
    *v = x;
    return mon_fault ? -1 : 0;
}

static int safe_write(uint32_t a, uint32_t v)
{
    trap_handler_t old = trap_set_exc_handler(mon_exc);
    mon_fault = 0;
    REG32(a) = v;
    trap_set_exc_handler(old);
    return mon_fault ? -1 : 0;
}

/* ---- commands ---- */
static const mon_cmd_t *ext_cmds;
static unsigned n_ext;

static int cmd_help(int argc, char **argv);

static int cmd_peek(int argc, char **argv)
{
    uint32_t a, n = 1, v;
    if (argc < 2 || mon_parse_addr(argv[1], &a)) { puts_("ERR address\n"); return -1; }
    if (argc > 2 && (parse_u32(argv[2], &n) || n == 0 || n > 256)) { puts_("ERR count\n"); return -1; }
    if (a & 3) { puts_("ERR alignment\n"); return -1; }
    for (uint32_t i = 0; i < n; i++, a += 4) {
        if (safe_read(a, &v)) { printf_("ERR fault 0x%08x\n", (unsigned)a); return -1; }
        printf_("0x%08x: 0x%08x\n", (unsigned)a, (unsigned)v);
    }
    return 0;
}

static int cmd_poke(int argc, char **argv)
{
    uint32_t a, v;
    if (argc < 3 || mon_parse_addr(argv[1], &a)) { puts_("ERR address\n"); return -1; }
    if (parse_u32(argv[2], &v)) { puts_("ERR value\n"); return -1; }
    if (a & 3) { puts_("ERR alignment\n"); return -1; }
    if (safe_write(a, v)) { printf_("ERR fault 0x%08x\n", (unsigned)a); return -1; }
#if PLATFORM_HAS_SOC
    /* make the write visible in RAM (other masters, uncached alias, I$) */
    if (a >= RAM_BASE && a < RAM_BASE + RAM_SIZE && dcache_clean()) {
        puts_("ERR write-back\n");
        return -1;
    }
#endif
    puts_("OK\n");
    return 0;
}

static int cmd_regs(int argc, char **argv)
{
    const blk_t *b = argc > 1 ? find_block(argv[1], strlen(argv[1])) : 0;
    if (!b) {
        puts_("ERR block: uart intc pmu timer wtimer handoff\n");
        return -1;
    }
    for (unsigned i = 0; i < b->n; i++) {
        uint32_t v;
        if (!strcmp(b->name, "uart") && b->regs[i].off == UART_RXDATA) continue; /* pops RX */
        if (safe_read(b->base + b->regs[i].off, &v)) {
            printf_("%s.%s: ERR fault\n", b->name, b->regs[i].name);
            continue;
        }
        printf_("%s.%-11s 0x%08x: 0x%08x\n", b->name, b->regs[i].name,
                (unsigned)(b->base + b->regs[i].off), (unsigned)v);
    }
    return 0;
}

static int cmd_go(int argc, char **argv)
{
    uint32_t a;
    if (argc < 2 || mon_parse_addr(argv[1], &a)) { puts_("ERR address\n"); return -1; }
    printf_("jumping to 0x%08x\n", (unsigned)a);
    uart_flush();
    if (cache_sync_icache()) { puts_("ERR write-back\n"); return -1; }
    ((void (*)(void))(uintptr_t)a)();
    return 0;
}

static const mon_cmd_t base_cmds[] = {
    {"help",  "",                "this list",                 cmd_help},
    {"peek",  "<addr|reg> [n]",  "read n words",              cmd_peek},
    {"poke",  "<addr|reg> <val>","write a word",              cmd_poke},
    {"regs",  "<block>",         "dump uart|intc|pmu|timer|wtimer|handoff", cmd_regs},
    {"go",    "<addr>",          "jump to address",           cmd_go},
};

static void help_list(const mon_cmd_t *c, unsigned n)
{
    for (unsigned i = 0; i < n; i++)
        printf_("  %-6s %-17s %s\n", c[i].name, c[i].args, c[i].help);
}

static int cmd_help(int argc, char **argv)
{
    (void)argc; (void)argv;
    help_list(base_cmds, ARRAY_SIZE(base_cmds));
    help_list(ext_cmds, n_ext);
    puts_("  registers: <block>.<name>, e.g. pmu.status\n");
    return 0;
}

static const mon_cmd_t *lookup(const char *name)
{
    for (unsigned i = 0; i < ARRAY_SIZE(base_cmds); i++)
        if (!strcmp(base_cmds[i].name, name)) return &base_cmds[i];
    for (unsigned i = 0; i < n_ext; i++)
        if (!strcmp(ext_cmds[i].name, name)) return &ext_cmds[i];
    return 0;
}

static unsigned read_line(char *buf, unsigned max)
{
    unsigned n = 0;
    for (;;) {
        int c = getch_nb();
        if (c < 0) continue;
        if (c == '\r' || c == '\n') {
            putch('\n');
            buf[n] = 0;
            return n;
        }
        if ((c == 8 || c == 127) && n) {
            n--;
            puts_("\b \b");
            continue;
        }
        if (c >= 32 && c < 127 && n + 1 < max) {
            buf[n++] = (char)c;
            putch((char)c);
        }
    }
}

void monitor_run(const mon_cmd_t *extra, unsigned n_extra)
{
    char line[96];
    char *argv[8];
    ext_cmds = extra;
    n_ext = n_extra;
    puts_("monitor ready, 'help' for commands\n");
    for (;;) {
        puts_(MON_PROMPT);
        read_line(line, sizeof(line));
        int argc = 0;
        char *p = line;
        while (*p && argc < 8) {
            while (*p == ' ') *p++ = 0;
            if (!*p) break;
            argv[argc++] = p;
            while (*p && *p != ' ') p++;
        }
        if (!argc) continue;
        const mon_cmd_t *c = lookup(argv[0]);
        if (!c) {
            printf_("ERR unknown command '%s'\n", argv[0]);
            continue;
        }
        c->fn(argc, argv);
    }
}
