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

/* ------------------------------------------------------------ debug blocks
 * doc/DEBUG_SPEC.md (normative for these registers): trace buffer, event
 * counters, error log, watchdog at DBG_BASE + 0x0000 / 0x1000 / 0x2000 /
 * 0x3000; 0x2000_C000-0x2000_FFFF reserved (SLVERR). */
#define DBG_TRACE_BASE      (DBG_BASE + _U(0x0000))
#define DBG_EVCNT_BASE      (DBG_BASE + _U(0x1000))
#define DBG_ERRLOG_BASE     (DBG_BASE + _U(0x2000))
#define DBG_WDT_BASE        (DBG_BASE + _U(0x3000))
#define DBG_ID              0x000
#define DBG_ID_TRACE        _U(0xDB600101)
#define DBG_ID_EVCNT        _U(0xDB600201)
#define DBG_ID_ERRLOG       _U(0xDB600301)
#define DBG_ID_WDT          _U(0xDB600401)
/* power-state encoding of the debug blocks (PMU stable state) */
#define DBG_PS_RUN          0
#define DBG_PS_IDLE         1
#define DBG_PS_SLEEP        2
#define DBG_PS_DSLEEP       3
/* trace buffer */
#define TRC_CTRL            0x004
#define TRC_STATUS          0x008
#define TRC_TRIG            0x00C
#define TRC_START_PC        0x010
#define TRC_STOP_PC         0x014
#define TRC_PC_MASK         0x018
#define TRC_WPTR            0x01C
#define TRC_COUNT           0x020
#define TRC_DEPTH           0x024
#define TRC_TOTAL           0x028
#define TRC_TSTAMP          0x02C
#define TRC_ENTRY(i)        (0x800 + 16 * (i))
#define TRC_CTRL_EN         (_U(1) << 0)
#define TRC_CTRL_CLEAR      (_U(1) << 1)
#define TRC_CTRL_FREEZE     (_U(1) << 2)
#define TRC_CTRL_LOG_TRAP   (_U(1) << 3)
#define TRC_CTRL_LOG_PWR    (_U(1) << 4)
#define TRC_CTRL_FRZ_EXC    (_U(1) << 5)
#define TRC_CTRL_FRZ_ERR    (_U(1) << 6)
#define TRC_ST_ACTIVE       (_U(1) << 0)
#define TRC_ST_FROZEN       (_U(1) << 1)
#define TRC_ST_WRAPPED      (_U(1) << 2)
#define TRC_ST_STOPPED      (_U(1) << 3)
#define TRC_ST_ARMED        (_U(1) << 4)
#define TRC_ST_CLR_PEND     (_U(1) << 5)
#define TRC_TRIG_NONE       0
#define TRC_TRIG_PC         1
#define TRC_TRIG_EXC        2
#define TRC_TRIG_PWR        3
#define TRC_INFO_TYPE(x)    ((x) & _U(3))
#define TRC_INFO_PSTATE(x)  (((x) >> 2) & _U(3))
#define TRC_INFO_CAUSE(x)   ((((x) >> 16) & _U(0xFF)) | ((x) & _U(0x80000000)))
#define TRC_TYPE_RETIRE     0
#define TRC_TYPE_TRAP       1
#define TRC_TYPE_PWR        2
/* event counters */
#define EVC_CTRL            0x004
#define EVC_STATUS          0x008
#define EVC_IC_HIT          0x010
#define EVC_IC_MISS         0x014
#define EVC_DC_HIT          0x018
#define EVC_DC_MISS         0x01C
#define EVC_STALL           0x020
#define EVC_WAKE            0x024
#define EVC_DVFS            0x028
#define EVC_TRANS           0x02C
#define EVC_T_LO(s)         (0x030 + 8 * (s))
#define EVC_T_HI(s)         (0x034 + 8 * (s))
#define EVC_PSTATE          0x050
#define EVC_CTRL_FREEZE     (_U(1) << 0)
#define EVC_CTRL_CLEAR      (_U(1) << 1)
#define EVC_CTRL_FRZ_ERR    (_U(1) << 2)
#define EVC_ST_FROZEN       (_U(1) << 0)
#define EVC_ST_CLR_PEND     (_U(1) << 1)
/* error log */
#define ERR_STATUS          0x004
#define ERR_CTRL            0x008
#define ERR_IRQ_EN          0x00C
#define ERR_FRZ_EN          0x010
#define ERR_SW_ERR          0x014
#define ERR_SW_CODE         0x018
#define ERR_EXC_CAUSE       0x020
#define ERR_EXC_PC          0x024
#define ERR_EXC_TVAL        0x028
#define ERR_EXC_TS          0x02C
#define ERR_EXC_CNT         0x030
#define ERR_PWR_LAST        0x040
#define ERR_PWR_TS          0x044
#define ERR_PWR_ERR_LAST    0x048
#define ERR_PWR_ERR_TS      0x04C
#define ERR_WDT_CNT         0x050
#define ERR_WDT_TS          0x054
#define ERR_WDT_PSTATE      0x058
#define ERR_TSTAMP          0x05C
#define ERR_ST_EXC          (_U(1) << 0)
#define ERR_ST_EXC_OVR      (_U(1) << 1)
#define ERR_ST_PWR_ERR      (_U(1) << 2)
#define ERR_ST_WDT_BITE     (_U(1) << 3)
#define ERR_ST_WDT_RST      (_U(1) << 4)
#define ERR_ST_SW_ERR       (_U(1) << 5)
#define ERR_ST_ALL          _U(0x3F)
#define ERR_PWR_FROM(v)     ((v) & _U(3))
#define ERR_PWR_TO(v)       (((v) >> 2) & _U(3))
#define ERR_PWR_RESULT(v)   (((v) >> 4) & _U(3))
#define ERR_PWR_COUNT(v)    ((v) >> 16)
#define ERR_RES_OK          0
#define ERR_RES_TIMEOUT     1
#define ERR_RES_ABORTED     2
#define ERR_RES_REFUSED     3
/* watchdog */
#define WDT_CTRL            0x004
#define WDT_LOAD            0x008
#define WDT_BARK            0x00C
#define WDT_COUNT           0x010
#define WDT_KICK            0x014
#define WDT_STATUS          0x018
#define WDT_RST_CNT         0x01C
#define WDT_CTRL_EN         (_U(1) << 0)
#define WDT_CTRL_BARK_EN    (_U(1) << 1)
#define WDT_CTRL_RST_EN     (_U(1) << 2)
#define WDT_CTRL_PAUSE_LP   (_U(1) << 3)
#define WDT_CTRL_LOCK       (_U(1) << 31)
#define WDT_KICK_KEY        _U(0x5A5AA5A5)
#define WDT_ST_BARK         (_U(1) << 0)
#define WDT_ST_BITE         (_U(1) << 1)
#define WDT_ST_RST_PEND     (_U(1) << 2)
#define WDT_ST_BAD_KICK     (_U(1) << 3)

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
