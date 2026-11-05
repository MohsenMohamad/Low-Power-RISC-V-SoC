/*
 * UART bring-up monitor (built into the boot ROM fallback and the app).
 *
 *   help                      list commands
 *   peek <addr|reg> [n]       read n words (default 1)
 *   poke <addr|reg> <value>   write one word (cached RAM: line is cleaned)
 *   regs <block>              dump a register block (uart intc pmu timer
 *                             cache handoff)
 *   go <addr>                 jump to address
 *   reset                     software reset of PD_CPU (cold boot path)
 *
 * Accesses that trap (e.g. access faults on the in-house core) are caught
 * and reported as "ERR fault" instead of crashing the monitor.
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
    {"data", UART_DATA}, {"status", UART_STATUS}, {"ie", UART_IE}, {"div", UART_DIV},
};
static const reg_t intc_regs[] = {
    {"pending", INTC_PENDING}, {"enable", INTC_ENABLE}, {"soft", INTC_SOFT_SET},
    {"soft_clr", INTC_SOFT_CLR}, {"claim", INTC_CLAIM}, {"raw", INTC_RAW},
};
static const reg_t pmu_regs[] = {
    {"ctrl", PMU_CTRL}, {"status", PMU_STATUS}, {"wake_en", PMU_WAKE_EN},
    {"dvfs_op", PMU_DVFS_OP}, {"rst_cause", PMU_RST_CAUSE}, {"event", PMU_EVENT},
    {"event_ie", PMU_EVENT_IE}, {"cnt_idle", PMU_CNT_IDLE}, {"cnt_sleep", PMU_CNT_SLEEP},
    {"cnt_deep", PMU_CNT_DEEP}, {"cnt_dvfs", PMU_CNT_DVFS}, {"cnt_abort", PMU_CNT_ABORT},
    {"off_time", PMU_OFF_TIME}, {"wake_src", PMU_WAKE_SRC}, {"id", PMU_ID},
};
static const reg_t timer_regs[] = {
    {"msip", CLINT_MSIP}, {"mtimecmp", CLINT_MTIMECMP}, {"mtimecmph", CLINT_MTIMECMP + 4},
    {"prescale", CLINT_PRESCALE}, {"mtime", CLINT_MTIME}, {"mtimeh", CLINT_MTIME + 4},
};
static const reg_t cache_regs[] = {
    {"ctrl", CACHE_CTRL}, {"line_addr", CACHE_LINE_ADDR}, {"dc_hit", CACHE_DC_HIT},
    {"dc_miss", CACHE_DC_MISS}, {"dc_wb", CACHE_DC_WB}, {"ic_hit", CACHE_IC_HIT},
    {"ic_miss", CACHE_IC_MISS}, {"info", CACHE_INFO},
};
static const reg_t handoff_regs[] = {
    {"soft_mtvec", 0x00}, {"boot_status", 0x04}, {"rst_cause", 0x08}, {"cold_boots", 0x0C},
    {"resumes", 0x10}, {"bad_resumes", 0x14}, {"rom_version", 0x18}, {"signature", 0x1C},
    {"ctx_magic", 0x40},
};

static const blk_t blocks[] = {
    {"uart",    UART_BASE,    uart_regs,    ARRAY_SIZE(uart_regs)},
    {"intc",    INTC_BASE,    intc_regs,    ARRAY_SIZE(intc_regs)},
    {"pmu",     PMU_BASE,     pmu_regs,     ARRAY_SIZE(pmu_regs)},
    {"timer",   CLINT_BASE,   timer_regs,   ARRAY_SIZE(timer_regs)},
    {"cache",   CACHE_BASE,   cache_regs,   ARRAY_SIZE(cache_regs)},
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
    if (a >= RAM_BASE && a < RAM_BASE + RAM_SIZE) dcache_clean_range((const void *)(uintptr_t)a, 4);
#endif
    puts_("OK\n");
    return 0;
}

static int cmd_regs(int argc, char **argv)
{
    const blk_t *b = argc > 1 ? find_block(argv[1], strlen(argv[1])) : 0;
    if (!b) {
        puts_("ERR block: uart intc pmu timer cache handoff\n");
        return -1;
    }
    for (unsigned i = 0; i < b->n; i++) {
        uint32_t v;
        if (!strcmp(b->name, "uart") && b->regs[i].off == UART_DATA) continue; /* pops RX */
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
    dcache_clean_all();
    icache_inv_all();
    ((void (*)(void))(uintptr_t)a)();
    return 0;
}

static int cmd_reset(int argc, char **argv)
{
    (void)argc; (void)argv;
    puts_("resetting CPU domain\n");
    pmu_sw_reset();
}

static const mon_cmd_t base_cmds[] = {
    {"help",  "",                "this list",                 cmd_help},
    {"peek",  "<addr|reg> [n]",  "read n words",              cmd_peek},
    {"poke",  "<addr|reg> <val>","write a word",              cmd_poke},
    {"regs",  "<block>",         "dump uart|intc|pmu|timer|cache|handoff", cmd_regs},
    {"go",    "<addr>",          "jump to address",           cmd_go},
    {"reset", "",                "software reset of PD_CPU",  cmd_reset},
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
