/* UART driver (polled TX/RX, FIFO status, interrupt enables). */
#include "drivers.h"

#define UART(off) REG32(UART_BASE + (off))

void uart_putc(char c)
{
    while (UART(UART_STATUS) & UART_ST_TX_FULL) ;
    UART(UART_DATA) = (uint8_t)c;
}

int uart_getc(void)
{
    if (!(UART(UART_STATUS) & UART_ST_RX_AVAIL)) return -1;
    return (int)(UART(UART_DATA) & 0xFFu);
}

void uart_flush(void)
{
    while (!(UART(UART_STATUS) & UART_ST_TX_IDLE)) ;
}

void uart_set_div(uint32_t div)
{
    uart_flush();
    UART(UART_DIV) = div;
}

uint32_t uart_get_div(void)
{
    return UART(UART_DIV);
}

uint32_t uart_status(void)
{
    return UART(UART_STATUS);
}

void uart_set_ie(uint32_t ie)
{
    UART(UART_IE) = ie;
}
