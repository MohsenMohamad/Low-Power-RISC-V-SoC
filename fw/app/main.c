/*
 * Application: validation suite + UART bring-up monitor.
 *
 * Boot argument (testbench / platform): run a test or the whole suite and
 * exit with the pass/fail signature, or start the monitor.
 */
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"
#include "pm.h"
#include "test.h"

#ifndef ARCH_NAME
#define ARCH_NAME "?"
#endif

static int autorun;

static __attribute__((unused)) const char *boot_str(uint32_t b)
{
    switch (b) {
    case BOOT_COLD:          return "cold";
    case BOOT_RESUMED:       return "resumed";
    case BOOT_RESUME_BADCTX: return "cold (bad resume context)";
    default:                 return "?";
    }
}

static int cmd_list(int argc, char **argv)
{
    (void)argc; (void)argv;
    suite_list();
    return 0;
}

static int cmd_run(int argc, char **argv)
{
    uint32_t id;
    if (argc < 2) { puts_("ERR usage: run <id|all>\n"); return -1; }
    if (!strcmp(argv[1], "all")) id = BOOTARG_ALL;
    else if (parse_u32(argv[1], &id) || id >= BOOTARG_ALL) { puts_("ERR id\n"); return -1; }
    suite_run(id);
    return 0;
}

static int cmd_info(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf_("platform %s, cpu %s, caps 0x%08x\n", PLATFORM_NAME, ARCH_NAME, (unsigned)suite_caps());
#if PLATFORM_HAS_SOC
    volatile handoff_t *h = HANDOFF;
    printf_("boot %s, rst_cause %u, cold_boots %u, resumes %u, bad_resumes %u\n",
            boot_str(h->boot_status), (unsigned)h->rst_cause, (unsigned)h->cold_boots,
            (unsigned)h->resumes, (unsigned)h->bad_resumes);
    if (pmu_present())
        printf_("opp %u, mtime %u\n", (unsigned)pmu_cur_op(), (unsigned)timer_now());
#endif
    return 0;
}

static int cmd_sleep(int argc, char **argv)
{
    uint32_t ticks;
    enum pm_state st;
    if (argc < 3 || parse_u32(argv[2], &ticks)) { puts_("ERR usage: sleep <idle|sleep|deep> <ticks>\n"); return -1; }
    if (!strcmp(argv[1], "idle")) st = PM_IDLE;
    else if (!strcmp(argv[1], "sleep")) st = PM_SLEEP;
    else if (!strcmp(argv[1], "deep")) st = PM_DEEP_SLEEP;
    else { puts_("ERR state\n"); return -1; }
    if (!pmu_present()) { puts_("ERR no PMU\n"); return -1; }
    uart_flush();
    pmu_set_wake(PMU_WAKE_MTIP);
    timer_set_cmp(timer_now() + ticks);
    int r = pm_suspend(st, 0);
    timer_cancel();
    printf_("woke: result %d, rst_cause %u, off_time %u\n", r,
            (unsigned)pmu_rst_cause(), (unsigned)pmu_read(PMU_OFF_TIME));
    return r < 0;
}

static int cmd_opp(int argc, char **argv)
{
    uint32_t op;
    if (argc < 2 || parse_u32(argv[1], &op)) { puts_("ERR usage: opp <0..2>\n"); return -1; }
    int r = pm_set_opp(op);
    if (r) { printf_("ERR opp %d\n", r); return -1; }
    printf_("opp %u\n", (unsigned)pmu_cur_op());
    return 0;
}

static int cmd_exit(int argc, char **argv)
{
    uint32_t code = 0;
    if (argc > 1) parse_u32(argv[1], &code);
    platform_exit(code);
}

static const mon_cmd_t app_cmds[] = {
    {"list",  "",                  "list validation tests",      cmd_list},
    {"run",   "<id|all>",          "run test(s)",                cmd_run},
    {"info",  "",                  "boot / platform information", cmd_info},
    {"sleep", "<idle|sleep|deep> <t>", "enter power state for t mtime ticks", cmd_sleep},
    {"opp",   "<0..2>",            "set CPU operating point",    cmd_opp},
    {"exit",  "[code]",            "end simulation",             cmd_exit},
};

static void finish_or_monitor(uint32_t sig)
{
    if (autorun) platform_exit((sig & 0xFFFF0000u) == SIG_PASS(0) ? 0 : sig);
    monitor_run(app_cmds, ARRAY_SIZE(app_cmds));
}

int main(void)
{
    arch_init();
    platform_init();

    uint32_t arg = platform_boot_arg();
    autorun = (arg & BOOTARG_AUTORUN) != 0;

    printf_("[APP] LPSOC firmware, platform %s, cpu %s", PLATFORM_NAME, ARCH_NAME);
#if PLATFORM_HAS_SOC
    printf_(", boot %s", boot_str(HANDOFF->boot_status));
#endif
    putch('\n');

    uint32_t sig;
    if (suite_resume_after_reboot(&sig)) finish_or_monitor(sig);

    if (autorun) finish_or_monitor(suite_run(BOOTARG_TEST(arg)));
    monitor_run(app_cmds, ARRAY_SIZE(app_cmds));
}
