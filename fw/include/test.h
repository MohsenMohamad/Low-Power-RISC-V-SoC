/*
 * Self-checking validation test framework.
 *
 * Every test returns TEST_PASS (0) or a non-zero failure code (by convention
 * the source line of the failing check). A test that needs a CPU reset to
 * complete returns TEST_REBOOT after arming the reboot and provides an
 * after_reboot() function that finishes the check on the next boot.
 */
#ifndef TEST_H
#define TEST_H

#include <stdint.h>
#include "lib.h"

#define TEST_PASS     0
#define TEST_SKIP     (-1)

typedef struct {
    uint16_t    id;
    const char *name;
    uint32_t    caps;                    /* required capabilities         */
    int       (*run)(void);
    int       (*after_reboot)(void);     /* optional                      */
} test_t;

#define TEST_DEFINE(id_, name_, caps_, fn_, post_)                          \
    static const test_t __test_##fn_                                        \
        __attribute__((used, section(".testtab"), aligned(4))) =            \
        { (id_), (name_), (caps_), (fn_), (post_) }

#define TEST(id_, name_, caps_, fn_) TEST_DEFINE(id_, name_, caps_, fn_, 0)

void test_fail_msg(const char *expr, const char *file, int line);

#define CHECK(c) do { if (!(c)) {                                           \
        test_fail_msg(#c, __FILE__, __LINE__); return __LINE__; } } while (0)

#define CHECK_EQ(a, b) do { uint32_t _a = (uint32_t)(a), _b = (uint32_t)(b);\
        if (_a != _b) {                                                     \
            printf_("    %s = 0x%08x, expected 0x%08x\n", #a, (unsigned)_a, (unsigned)_b); \
            test_fail_msg(#a " == " #b, __FILE__, __LINE__);                \
            return __LINE__; } } while (0)

/* Suite runner (app/suite.c) */
uint32_t suite_caps(void);
const test_t *suite_find(uint32_t id);
void suite_list(void);
/* Run one test (id) or all (BOOTARG_ALL). Returns the signature. */
uint32_t suite_run(uint32_t id);
/* After boot: finish a test that rebooted the CPU. Returns 1 if a suite run
 * was in progress (it is continued and completed). */
int suite_resume_after_reboot(uint32_t *signature);
/* Arm a test that reboots the CPU (persists runner state). */
void suite_prepare_reboot(void);

#define SIG_PASS(n)  (0x600D0000u | ((n) & 0xFFFFu))
#define SIG_FAIL(n)  (0xBAD00000u | ((n) & 0xFFFFu))

#endif
