/*
 * UART monitor commands shared by the applications (fw/app/main.c,
 * fw/debug/dbg_app.c): enter a power state, change the operating point, end
 * the run. One implementation, so the bench protocol (tools/bench) is the
 * same for every image.
 */
#include "app_cmds.h"
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"
#include "pm.h"

#if PLATFORM_HAS_SOC
/* Enter a power state; wake by the machine timer after <ticks> or by a byte
 * on the UART (RX interrupt -> intc source 0 -> MEIP). Succeeds only if the
 * requested transition completed (doc/SPEC.md: an aborted transition is not
 * a success). */
int cmd_sleep(int argc, char **argv)
{
    uint32_t ticks = 0;
    enum pm_state st;
    int uart_wake = argc >= 3 && !strcmp(argv[2], "uart");
    if (argc < 3 || (!uart_wake && parse_u32(argv[2], &ticks))) {
        puts_("ERR usage: sleep <idle|sleep|deep> <ticks|uart>\n");
        return -1;
    }
    if (!strcmp(argv[1], "idle")) st = PM_IDLE;
    else if (!strcmp(argv[1], "sleep")) st = PM_SLEEP;
    else if (!strcmp(argv[1], "deep")) st = PM_DEEP_SLEEP;
    else { puts_("ERR state\n"); return -1; }
    uint32_t mie = arch_irq_mask_save(0);
    if (uart_wake) {
        uart_set_ie(UART_CTRL_RX_IE);
        intc_set_enabled(IRQ_UART);
        arch_irq_enable(IRQ_MEI);
        puts_(MON_WAKE_PROMPT);
        uart_flush();
    } else {
        uart_flush();
        if (dcache_clean()) { puts_("ERR write-back\n"); arch_irq_mask_restore(mie); return -1; }
        arch_irq_enable(IRQ_MTI);
        timer_set_cmp(timer_now() + ticks);
    }
    uint32_t cnt0 = pmu_sleep_count();
    int r = pm_suspend(st, 0);
    timer_cancel();
    uart_set_ie(0);
    intc_set_enabled(0);
    arch_irq_mask_restore(mie);
    if (uart_wake) putch('\n');
    printf_("woke: result %d, rst_cause %u, wake_cause %u, sleep_cnt +%u\n", r,
            (unsigned)HANDOFF->rst_cause, (unsigned)pmu_wake_cause(),
            (unsigned)(pmu_sleep_count() - cnt0));
    int want = (st == PM_IDLE) ? PM_WOKE : PM_RESUMED;
    if (r != want) { printf_("ERR transition %s\n", r == PM_ABORTED ? "ABORTED" : "failed"); return -1; }
    return 0;
}

int cmd_opp(int argc, char **argv)
{
    uint32_t op;
    if (argc < 2 || parse_u32(argv[1], &op)) { puts_("ERR usage: opp <0..2>\n"); return -1; }
    int r = pm_set_opp(op);
    if (r) { printf_("ERR opp %d\n", r); return -1; }
    printf_("opp %u\n", (unsigned)pmu_cur_op());
    return 0;
}
#endif

int cmd_exit(int argc, char **argv)
{
    uint32_t code = 0;
    if (argc > 1 && parse_u32(argv[1], &code)) code = 0xE0000000u;
    platform_exit(code);
}

