/*
 * Validation-suite application: validation suite + UART bring-up monitor.
 *
 * Boot argument (platform_boot_arg: host mailbox on lpsoc, built in on
 * Spike): run one test or the whole suite and exit with the pass/fail
 * signature, or start the monitor.
 */
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"
#include "pm.h"
#include "test.h"
#include "app_cmds.h"

#ifndef ARCH_NAME
#define ARCH_NAME "?"
#endif

static int autorun;

static __attribute__((unused)) const char *boot_str(uint32_t b)
{
    switch (b) {
    case BOOT_COLD:          return "cold";
    case BOOT_RESUMED:       return "resumed";
    case BOOT_RESUME_BADCTX: return "cold (resume rejected)";
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
    uint32_t sig = suite_run(id);
    return (sig & 0xFFFF0000u) == SIG_PASS(0) ? 0 : -1;
}

static int cmd_info(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf_("platform %s, cpu %s, caps 0x%08x\n", PLATFORM_NAME, ARCH_NAME, (unsigned)suite_caps());
#if PLATFORM_HAS_SOC
    volatile handoff_t *h = HANDOFF;
    printf_("boot %s, rst_cause %u, reason %u, cold_boots %u, resumes %u, bad_resumes %u\n",
            boot_str(h->boot_status), (unsigned)h->rst_cause, (unsigned)h->boot_reason,
            (unsigned)h->cold_boots, (unsigned)h->resumes, (unsigned)h->bad_resumes);
    printf_("opp %u, sleep_cnt %u, mtime %u\n", (unsigned)pmu_cur_op(),
            (unsigned)pmu_sleep_count(), (unsigned)timer_now());
#endif
    return 0;
}

static const mon_cmd_t app_cmds[] = {
    {"list",  "",                  "list validation tests",      cmd_list},
    {"run",   "<id|all>",          "run test(s)",                cmd_run},
    {"info",  "",                  "boot / platform information", cmd_info},
#if PLATFORM_HAS_SOC
    {"sleep", "<state> <t|uart>",  "idle|sleep|deep for t ticks or until UART input", cmd_sleep},
    {"opp",   "<0..2>",            "set CPU operating point",    cmd_opp},
#endif
    {"exit",  "[code]",            "end the run (PASS / FAIL)",  cmd_exit},
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
