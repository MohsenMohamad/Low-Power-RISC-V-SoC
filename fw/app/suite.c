/*
 * Validation suite runner.
 *
 * Tests live in the .testtab section and run in id order. The runner state
 * is kept in the persistent RAM area (uncached alias) so that tests which
 * reset the CPU (software reset, failed resume) are completed after the
 * reboot and the run continues where it stopped.
 *
 * Output per test:   [TEST  42] pm_sleep_resume              PASS
 * Final lines:       SUITE DONE pass=N fail=N skip=N signature=0x........
 *                    SUITE RESULT: PASS | FAIL
 * Signature: 0x600Dnnnn (all passed, nnnn = passed count) or
 *            0xBAD0nnnn (nnnn = failed count).
 */
#include "test.h"
#include "arch.h"
#include "drivers.h"
#include "handoff.h"
#include "platform_api.h"
#include "trap.h"
#include "pm.h"

#define SUITE_MAGIC 0x53554954u   /* "SUIT" */
#define MAX_TESTS   96

typedef struct {
    uint32_t magic;
    uint32_t target;        /* test id or BOOTARG_ALL      */
    uint32_t next_idx;      /* next index in sorted order  */
    uint32_t reboot_id;     /* test waiting for its reboot */
    uint32_t pass, fail, skip;
    uint32_t failed[8];
} suite_state_t;

#if PLATFORM_HAS_SOC
#define ST ((volatile suite_state_t *)(PERSIST_ADDR + RAM_UNCACHED_OFFSET))
#else
static suite_state_t st_mem;
#define ST ((volatile suite_state_t *)&st_mem)
#endif

extern const test_t __testtab_start[], __testtab_end[];

static const test_t *sorted[MAX_TESTS];
static unsigned n_tests;

static void sort_tests(void)
{
    n_tests = 0;
    for (const test_t *t = __testtab_start; t < __testtab_end && n_tests < MAX_TESTS; t++) {
        unsigned i = n_tests++;
        while (i && sorted[i - 1]->id > t->id) { sorted[i] = sorted[i - 1]; i--; }
        sorted[i] = t;
    }
}

uint32_t suite_caps(void)
{
    return arch_caps() | platform_caps();
}

const test_t *suite_find(uint32_t id)
{
    if (!n_tests) sort_tests();
    for (unsigned i = 0; i < n_tests; i++)
        if (sorted[i]->id == id) return sorted[i];
    return 0;
}

static const char *cap_names[16] = {
    "mcsr", "counters", "misalign", "accfault", 0, 0, 0, 0,
    "mtimer", "intc", "uart", "pmu", "cache", "dvfs", "bootrom", "wtimer",
};

static void print_caps(uint32_t c)
{
    for (unsigned i = 0; i < 16; i++)
        if ((c & (1u << i)) && cap_names[i]) printf_(" %s", cap_names[i]);
}

void suite_list(void)
{
    if (!n_tests) sort_tests();
    uint32_t have = suite_caps();
    for (unsigned i = 0; i < n_tests; i++) {
        const test_t *t = sorted[i];
        printf_("  %3u %-28s%s", t->id, t->name, (t->caps & ~have) ? " (unsupported:" : "");
        if (t->caps & ~have) { print_caps(t->caps & ~have); putch(')'); }
        putch('\n');
    }
}

void test_fail_msg(const char *expr, const char *file, int line)
{
    printf_("    CHECK FAILED: %s (%s:%d)\n", expr, file, line);
}

static void record(const test_t *t, int r, const char *note)
{
    volatile suite_state_t *s = ST;
    const char *res;
    if (r == TEST_SKIP) { s->skip = s->skip + 1; res = "SKIP"; }
    else if (r == TEST_PASS) { s->pass = s->pass + 1; res = "PASS"; }
    else {
        if (s->fail < 8) s->failed[s->fail] = t->id;
        s->fail = s->fail + 1;
        res = "FAIL";
    }
    printf_("[TEST %3u] %-28s %s", t->id, t->name, res);
    if (r > 0) printf_(" (code %d)", r);
    if (note) printf_(" %s", note);
    putch('\n');
}

static uint32_t finish(void)
{
    volatile suite_state_t *s = ST;
    uint32_t sig = s->fail ? SIG_FAIL(s->fail) : SIG_PASS(s->pass);
    printf_("SUITE DONE pass=%u fail=%u skip=%u signature=0x%08x\n",
            (unsigned)s->pass, (unsigned)s->fail, (unsigned)s->skip, (unsigned)sig);
    if (s->fail) {
        puts_("FAILED:");
        for (unsigned i = 0; i < s->fail && i < 8; i++) printf_(" %u", (unsigned)s->failed[i]);
        putch('\n');
    }
    if (s->target == BOOTARG_ALL || s->pass + s->fail > 0)
        printf_("SUITE RESULT: %s\n", s->fail ? "FAIL" : "PASS");
    s->magic = 0;
#if PLATFORM_HAS_SOC
    HANDOFF->signature = sig;
#endif
    return sig;
}

/* Bring the platform back to a known baseline after every test, so that a
 * failing test cannot leave state behind that breaks the following ones:
 * interrupts off, timers stopped, intc disabled, PMU in IDLE mode at the
 * reset operating point (OP2). */
static void env_reset(void)
{
    uint32_t caps = suite_caps();
    (void)arch_irq_save();
    (void)arch_irq_mask_save(0);
    trap_set_exc_handler(0);
    if (caps & CAP_CLINT) {
        timer_cancel();
        timer_set_msip(0);
    }
    if (caps & CAP_UART) uart_set_ie(0);
    if (caps & CAP_WTIMER) wtimer_stop();
    if (caps & CAP_INTC) intc_set_enabled(0);
    if (caps & CAP_PMU) {
        pmu_set_mode(PMU_MODE_IDLE);
        pmu_write(PMU_IRQ_EN, 0);
        pmu_write(PMU_SCRATCH1, 0);
        pmu_clear_status(PMU_ST_W1C_ALL);
    }
    if ((caps & CAP_DVFS) && pmu_cur_op() != PMU_RESET_OP) (void)pm_set_opp(PMU_RESET_OP);
}

static uint32_t run_from_state(void)
{
    volatile suite_state_t *s = ST;
    uint32_t have = suite_caps();
    while (s->next_idx < n_tests) {
        const test_t *t = sorted[s->next_idx];
        s->next_idx = s->next_idx + 1;
        if (s->target != BOOTARG_ALL && t->id != s->target) continue;
        if (t->caps & ~have) {
            printf_("[TEST %3u] %-28s SKIP (needs", t->id, t->name);
            print_caps(t->caps & ~have);
            puts_(")\n");
            s->skip = s->skip + 1;
            continue;
        }
        printf_("[RUN  %3u] %s\n", t->id, t->name);
        if (t->after_reboot) s->reboot_id = t->id;
        int r = t->run();
        s->reboot_id = 0;
        env_reset();
        record(t, r, t->after_reboot ? "(no reboot happened)" : 0);
    }
    return finish();
}

uint32_t suite_run(uint32_t id)
{
    volatile suite_state_t *s = ST;
    sort_tests();
    if (id != BOOTARG_ALL && !suite_find(id)) {
        printf_("ERR no test %u\n", (unsigned)id);
        return SIG_FAIL(0xFFFF);
    }
    s->target = id;
    s->next_idx = 0;
    s->reboot_id = 0;
    s->pass = s->fail = s->skip = 0;
    s->magic = SUITE_MAGIC;
    printf_("SUITE START %s caps:", id == BOOTARG_ALL ? "all" : "single");
    print_caps(suite_caps());
    putch('\n');
    return run_from_state();
}

int suite_resume_after_reboot(uint32_t *signature)
{
    volatile suite_state_t *s = ST;
    if (s->magic != SUITE_MAGIC) return 0;
    sort_tests();
    if (s->reboot_id) {
        const test_t *t = suite_find(s->reboot_id);
        s->reboot_id = 0;
        if (t && t->after_reboot) {
            printf_("[CONT %3u] %s (after reboot)\n", t->id, t->name);
            record(t, t->after_reboot(), "(after reboot)");
            env_reset();
        }
    }
    *signature = run_from_state();
    return 1;
}

/* Persistent per-test scratch words for reboot tests. */
volatile uint32_t *suite_scratch(void);
volatile uint32_t *suite_scratch(void)
{
#if PLATFORM_HAS_SOC
    return (volatile uint32_t *)(PERSIST_ADDR + RAM_UNCACHED_OFFSET + 0x100);
#else
    static uint32_t scratch[16];
    return scratch;
#endif
}
