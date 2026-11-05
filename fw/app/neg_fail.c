/*
 * Negative test application for the SoC testbench: boots, reports a FAIL
 * verdict and stops. The testbench must report TEST FAILED and exit nonzero
 * (scripts/soc_neg.py).
 */
#include "arch.h"
#include "lib.h"
#include "platform_api.h"

int main(void)
{
    arch_init();
    puts_("\nlp-soc neg_fail\n");
    platform_exit(1);
}
