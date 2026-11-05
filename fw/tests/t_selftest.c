/* Framework self-test (built only with -DSUITE_SELFTEST): tests whose outcome
 * is known, so that the reporting path (console result, signature, exit line,
 * host result checker) is itself verified:
 *   99 must FAIL (failing CHECK), 98 must SKIP (capability nobody has),
 *   97 must FAIL on the SoC: an IDLE request with an enabled interrupt already
 *      pending never gates the clock; a power test expecting a completed IDLE
 *      transition must report that as a failure (doc/SPEC.md: an aborted
 *      transition is never a pass). Before stage 2, pm_idle() returned
 *      PM_WOKE unconditionally and this test passed. */
#include "test.h"
#include "arch.h"
#include "drivers.h"
#include "platform_api.h"
#include "pm.h"

#ifdef SUITE_SELFTEST
static int t_must_fail(void)
{
    CHECK_EQ(1 + 1, 3);
    return TEST_PASS;
}
TEST(99, "selftest_must_fail", 0, t_must_fail);

static int t_must_skip(void)
{
    return TEST_PASS;
}
TEST(98, "selftest_must_skip", 1u << 7, t_must_skip);   /* capability nobody has */

static int t_idle_abort(void)
{
    uint32_t mie = arch_irq_mask_save(1u << IRQ_MSI);
    timer_set_msip(1);                       /* wake event already pending */
    int r = pm_idle();
    timer_set_msip(0);
    arch_irq_mask_restore(mie);
    CHECK_EQ(r, PM_WOKE);                    /* must fail: nothing was gated */
    return TEST_PASS;
}
TEST(97, "selftest_idle_abort_must_fail", CAP_PMU | CAP_CLINT, t_idle_abort);
#endif
