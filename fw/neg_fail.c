/*
 * Negative test firmware for the SoC testbench: boots, prints a FAIL verdict
 * and stops. The testbench must report TEST FAILED and exit nonzero
 * (scripts/soc_neg.py).
 */
#include <stdint.h>
#include "soc.h"

int main(void) {
  const char *s = "\nlp-soc neg_fail\nFAIL 0x00000001\n";
  while (*s) {
    while (REG32(UART_BASE, UART_TXDATA) & 0x80000000u) {}
    REG32(UART_BASE, UART_TXDATA) = (uint32_t)(uint8_t)*s++;
  }
  for (;;) {}
}
