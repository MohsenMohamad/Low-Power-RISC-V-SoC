/* Framework self-test (built only with -DSUITE_SELFTEST): one test that must
 * fail and one that must be skipped, so that the pass/fail reporting path
 * (console result, signature, simulator exit status) is itself verified. */
#include "test.h"

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
#endif
