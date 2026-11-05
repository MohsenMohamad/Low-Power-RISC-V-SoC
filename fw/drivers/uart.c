/* UART driver (doc/SOC_REGMAP.md: TXDATA 0x00, RXDATA 0x04, STATUS 0x08,
 * CTRL 0x0C = DIV[15:0] | RX_IE[16] | TX_IE[17]). Polled TX/RX. */
#include "drivers.h"

#define UART(off) REG32(UART_BASE + (off))

void uart_putc(char c)
{
    while (UART(UART_STATUS) & UART_ST_TX_FULL) ;
    UART(UART_TXDATA) = (uint8_t)c;
}

int uart_getc(void)
{
    if (!(UART(UART_STATUS) & UART_ST_RX_VALID)) return -1;
    uint32_t v = UART(UART_RXDATA);          /* a read pops one entry */
    if (v & UART_RXDATA_EMPTY) return -1;
    return (int)(v & 0xFFu);
}

void uart_flush(void)
{
    while (!(UART(UART_STATUS) & UART_ST_TX_IDLE)) ;
}

void uart_set_div(uint32_t div)
{
    uart_flush();
    UART(UART_CTRL) = (UART(UART_CTRL) & ~UART_CTRL_DIV_MASK) | (div & UART_CTRL_DIV_MASK);
}

uint32_t uart_get_div(void)
{
    return UART(UART_CTRL) & UART_CTRL_DIV_MASK;
}

uint32_t uart_status(void)
{
    return UART(UART_STATUS);
}

void uart_set_ie(uint32_t ie)
{
    uint32_t c = UART(UART_CTRL) & ~(UART_CTRL_RX_IE | UART_CTRL_TX_IE);
    UART(UART_CTRL) = c | (ie & (UART_CTRL_RX_IE | UART_CTRL_TX_IE));
}

uint32_t uart_get_ie(void)
{
    return UART(UART_CTRL) & (UART_CTRL_RX_IE | UART_CTRL_TX_IE);
}
