/*
 * Low-power RISC-V SoC: memory map and register definitions.
 *
 * Transcribed from doc/SOC_REGMAP.md (normative) and the doc/SPEC.md address
 * map. Any register change goes into doc/SOC_REGMAP.md first, then here.
 * Shared by C and assembler sources and by every platform port (the Spike
 * port uses only the CPU definitions at the end).
 */
#ifndef SOC_H
#define SOC_H

#ifdef __ASSEMBLER__
#define _U(x) x
#else
#include <stdint.h>
#define _U(x) x##u
#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#endif

/* ------------------------------------------------------------ memory map */
#define ROM_BASE            _U(0x00000000)
#define ROM_SIZE            _U(0x00004000)      /* 16 KB, reset vector 0 */
#define SOC_RAM_BASE        _U(0x10000000)
#define SOC_RAM_SIZE        _U(0x00020000)      /* 128 KB, PD_AON, retained */
#define UART_BASE           _U(0x20000000)
#define MTIMER_BASE         _U(0x20001000)
#define INTC_BASE           _U(0x20002000)
#define PMU_BASE            _U(0x20003000)
#define WTIMER_BASE         _U(0x20004000)
#define DBG_BASE            _U(0x20008000)      /* 32 KB debug range (doc/DEBUG_SPEC.md) */
#define RAM_ALIAS_BASE      _U(0x30000000)      /* uncached alias of the RAM */
#define RAM_UNCACHED_OFFSET (RAM_ALIAS_BASE - SOC_RAM_BASE)

/* ------------------------------------------------------------ UART */
#define UART_TXDATA         0x00    /* W: push byte; R: [31] TX FIFO full */
#define UART_RXDATA         0x04    /* R: pop byte [7:0]; [31] RX FIFO empty */
#define UART_STATUS         0x08
#define UART_CTRL           0x0C
#define UART_TXDATA_FULL    (_U(1) << 31)
#define UART_RXDATA_EMPTY   (_U(1) << 31)
#define UART_ST_TX_FULL     (_U(1) << 0)
#define UART_ST_TX_IDLE     (_U(1) << 1)
#define UART_ST_RX_VALID    (_U(1) << 2)
#define UART_ST_RX_OVERRUN  (_U(1) << 3)    /* W1C */
#define UART_CTRL_DIV_MASK  _U(0x0000FFFF)  /* clk_aon cycles per bit, >= 2 */
#define UART_CTRL_RX_IE     (_U(1) << 16)
#define UART_CTRL_TX_IE     (_U(1) << 17)
#define UART_FIFO_DEPTH     8

/* ------------------------------------------------------------ machine timer */
#define MTIME_LO            0x00
#define MTIME_HI            0x04
#define MTIMECMP_LO         0x08
#define MTIMECMP_HI         0x0C
#define MSIP                0x10

/* ------------------------------------------------------------ interrupt controller */
#define INTC_PENDING        0x00    /* RO raw source levels */
#define INTC_ENABLE         0x04    /* RW, byte lane 0 */
#define INTC_ACTIVE         0x08    /* RO PENDING & ENABLE */
#define INTC_SRC_UART       0
#define INTC_SRC_WTIMER     1
#define INTC_SRC_PMU        2
#define INTC_SRC_EXT_WAKE   3
#define INTC_SRC_DBG_ERR    4       /* debug error log (STATUS & IRQ_EN) */
#define INTC_SRC_WDT        5       /* watchdog bark */
#define INTC_NSRC           6       /* bits 7:6 reserved */
#define IRQ_UART            (_U(1) << INTC_SRC_UART)
#define IRQ_WTIMER          (_U(1) << INTC_SRC_WTIMER)
#define IRQ_PMU             (_U(1) << INTC_SRC_PMU)
#define IRQ_EXT_WAKE        (_U(1) << INTC_SRC_EXT_WAKE)
#define IRQ_DBG_ERR         (_U(1) << INTC_SRC_DBG_ERR)
#define IRQ_WDT             (_U(1) << INTC_SRC_WDT)

/* ------------------------------------------------------------ PMU */
#define PMU_CTRL            0x00
#define PMU_STATUS          0x04
#define PMU_DVFS            0x08
#define PMU_IRQ_EN          0x0C
#define PMU_SCRATCH0        0x10    /* boot ABI: context pointer */
#define PMU_SCRATCH1        0x14    /* boot ABI: resume magic */
#define PMU_WAKE_CAUSE      0x18
#define PMU_SLEEP_CNT       0x1C
#define PMU_VSEL            0x20
#define PMU_WAKE_MASK       0x24    /* [0] meip [1] mtip [2] msip, reset 0x7 */
#define PMU_IDLE_CNT        0x28    /* completed IDLE entries */

#define PMU_MODE_IDLE       _U(0)
#define PMU_MODE_SLEEP      _U(1)
#define PMU_MODE_DEEP       _U(2)
#define PMU_CTRL_LP_EN      (_U(1) << 8)
#define PMU_IRQ_EN_DVFS_DONE (_U(1) << 0)

#define PMU_ST_STATE(s)     ((s) & _U(0x1F))
#define PMU_ST_CUR_OP(s)    (((s) >> 8) & _U(0x3))
#define PMU_ST_DVFS_PEND    (_U(1) << 10)
#define PMU_ST_RESUME       (_U(1) << 16)
#define PMU_ST_RESUME_DEEP  (_U(1) << 17)
#define PMU_ST_DVFS_DONE    (_U(1) << 18)
#define PMU_ST_ERR_DIRTY    (_U(1) << 19)
#define PMU_ST_WDT_RST      (_U(1) << 20)   /* CPU reset by the watchdog */
#define PMU_ST_W1C_ALL      (PMU_ST_RESUME | PMU_ST_RESUME_DEEP | PMU_ST_DVFS_DONE | PMU_ST_ERR_DIRTY | \
                             PMU_ST_WDT_RST)
#define PMU_STATE_RUN       0
#define PMU_STATE_IDLE      3

/* WAKE_CAUSE and WAKE_MASK bits */
#define WAKE_MEIP           (_U(1) << 0)
#define WAKE_MTIP           (_U(1) << 1)
#define WAKE_MSIP           (_U(1) << 2)
#define WAKE_ALL            (WAKE_MEIP | WAKE_MTIP | WAKE_MSIP)

/* Operating points: OP0 slowest / lowest voltage .. OP2 fastest (reset). */
#define PMU_NUM_OPP         3
#define PMU_RESET_OP        2

/* ------------------------------------------------------------ wake timer */
#define WT_CTRL             0x00
#define WT_LOAD             0x04
#define WT_COUNT            0x08
#define WT_STATUS           0x0C
#define WT_CTRL_EN          (_U(1) << 0)
#define WT_CTRL_PERIODIC    (_U(1) << 1)
#define WT_ST_EXPIRED       (_U(1) << 0)

/* ------------------------------------------------------------ CPU (doc/CPU.md) */
#define CSR_MCACHECTL       0x7C0
#define MCACHECTL_DFLUSH    (_U(1) << 0)    /* D-cache clean + invalidate */
#define MCACHECTL_IINVAL    (_U(1) << 1)    /* I-cache invalidate */
#define MCACHECTL_DCLEAN    (_U(1) << 2)    /* D-cache clean */
#define MCACHECTL_WBERR     (_U(1) << 31)   /* read: write-back error */
#define CACHE_LINE_SIZE     16
#define CACHE_SIZE          4096
#define CACHE_WAYS          2
#define MIE_MSIE            (_U(1) << 3)
#define MIE_MTIE            (_U(1) << 7)
#define MIE_MEIE            (_U(1) << 11)
#define MSTATUS_MIE         (_U(1) << 3)

#endif
