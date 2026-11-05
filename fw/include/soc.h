/*
 * Low-power SoC memory map and register definitions.
 *
 * The same map is used by the in-house SoC and by its PicoRV32-based
 * bring-up version. Spike provides only RAM, a CLINT and HTIF; see
 * platform/spike/platform.h for its map.
 */
#ifndef SOC_H
#define SOC_H

#ifndef __ASSEMBLER__
#include <stdint.h>
#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#endif

/* ---------------------------------------------------------------- memory */
#define ROM_BASE            0x00000000u
#define ROM_SIZE            0x00004000u     /* 16 KB */
#define RAM_BASE_LPSOC      0x20000000u
#define RAM_SIZE_LPSOC      0x00020000u     /* 128 KB, PD_AON, retained */
#define RAM_UNCACHED_OFFSET 0x10000000u     /* 0x3000_0000: uncached RAM alias */

/* ---------------------------------------------------------------- UART */
#define UART_BASE           0x40000000u
#define UART_DATA           0x00u
#define UART_STATUS         0x04u
#define UART_IE             0x08u
#define UART_DIV            0x0Cu
#define UART_ST_TX_FULL     (1u << 0)
#define UART_ST_TX_IDLE     (1u << 1)
#define UART_ST_RX_AVAIL    (1u << 2)
#define UART_ST_RX_OVERRUN  (1u << 3)
#define UART_IE_RX          (1u << 0)
#define UART_IE_TX_IDLE     (1u << 1)

/* ---------------------------------------------------------------- INTC */
#define INTC_BASE           0x40001000u
#define INTC_PENDING        0x00u
#define INTC_ENABLE         0x04u
#define INTC_SOFT_SET       0x08u
#define INTC_SOFT_CLR       0x0Cu
#define INTC_CLAIM          0x10u
#define INTC_RAW            0x14u
#define INTC_NSRC           8
#define INTC_SRC_UART       0
#define INTC_SRC_PMU        1

/* ---------------------------------------------------------------- PMU */
#define PMU_BASE            0x40002000u
#define PMU_CTRL            0x00u
#define PMU_STATUS          0x04u
#define PMU_WAKE_EN         0x08u
#define PMU_DVFS_OP         0x0Cu
#define PMU_RST_CAUSE       0x10u
#define PMU_EVENT           0x14u
#define PMU_EVENT_IE        0x18u
#define PMU_SWRST           0x1Cu
#define PMU_CNT_IDLE        0x20u
#define PMU_CNT_SLEEP       0x24u
#define PMU_CNT_DEEP        0x28u
#define PMU_CNT_DVFS        0x2Cu
#define PMU_CNT_ABORT       0x30u
#define PMU_OFF_TIME        0x34u
#define PMU_WAKE_SRC        0x38u
#define PMU_ID              0x3Cu

#define PMU_ID_VALUE        0x504D5531u     /* "PMU1" */
#define PMU_MODE_IDLE       0u
#define PMU_MODE_SLEEP      1u
#define PMU_MODE_DEEP       2u
#define PMU_CTRL_DVFS_REQ   (1u << 4)
#define PMU_WAKE_MTIP       (1u << 0)
#define PMU_WAKE_MSIP       (1u << 1)
#define PMU_WAKE_MEIP       (1u << 2)
#define PMU_RC_POR          1u
#define PMU_RC_SLEEP        2u
#define PMU_RC_DEEP         3u
#define PMU_RC_SWRST        4u
#define PMU_EV_DVFS_DONE    (1u << 0)
#define PMU_EV_SLEEP_ABORT  (1u << 1)
#define PMU_SWRST_KEY       0x5AFE0001u
#define PMU_ST_CUR_OP(s)    ((s) & 3u)
#define PMU_ST_VSEL(s)      (((s) >> 2) & 3u)
#define PMU_NUM_OPP         3

/* ---------------------------------------------------------------- timer */
#define CLINT_BASE_LPSOC    0x40010000u
#define CLINT_MSIP          0x0000u
#define CLINT_MTIMECMP      0x4000u
#define CLINT_PRESCALE      0x8000u         /* lpsoc only */
#define CLINT_MTIME         0xBFF8u

/* ---------------------------------------------------------------- cache */
#define CACHE_BASE          0x50000000u
#define CACHE_CTRL          0x00u
#define CACHE_DC_CMD        0x04u
#define CACHE_IC_CMD        0x08u
#define CACHE_LINE_ADDR     0x0Cu
#define CACHE_DC_HIT        0x10u
#define CACHE_DC_MISS       0x14u
#define CACHE_DC_WB         0x18u
#define CACHE_IC_HIT        0x1Cu
#define CACHE_IC_MISS       0x20u
#define CACHE_INFO          0x3Cu
#define CACHE_CTRL_IC_EN    (1u << 0)
#define CACHE_CTRL_DC_EN    (1u << 1)
#define CACHE_CMD_INV_ALL    1u
#define CACHE_CMD_CLEAN_ALL  2u
#define CACHE_CMD_FLUSH_ALL  3u
#define CACHE_CMD_INV_LINE   4u
#define CACHE_CMD_CLEAN_LINE 5u
#define CACHE_CMD_FLUSH_LINE 6u
#define CACHE_LINE_SIZE     16u

/* ------------------------------------------------- simulation control */
#define SIMCTRL_BASE        0x4F000000u
#define SIMCTRL_EXIT        0x00u
#define SIMCTRL_ARG         0x04u
#define SIMCTRL_PUTC        0x08u
#define SIMCTRL_TIME        0x0Cu
#define SIMCTRL_ARG_PRESENT (1u << 31)
#define SIMCTRL_ARG_MONITOR (1u << 30)

#endif
