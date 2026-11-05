/* Low-power RISC-V SoC - memory map and register definitions. */
#ifndef SOC_H
#define SOC_H

#define ROM_BASE        0x00000000u
#define RAM_BASE        0x10000000u
#define UART_BASE       0x20000000u
#define MTIMER_BASE     0x20001000u
#define INTC_BASE       0x20002000u
#define PMU_BASE        0x20003000u
#define WTIMER_BASE     0x20004000u

/* UART */
#define UART_TXDATA     0x00
#define UART_RXDATA     0x04
#define UART_STATUS     0x08
#define UART_CTRL       0x0C

/* machine timer */
#define MTIME_LO        0x00
#define MTIME_HI        0x04
#define MTIMECMP_LO     0x08
#define MTIMECMP_HI     0x0C
#define MSIP            0x10

/* interrupt controller */
#define INTC_PENDING    0x00
#define INTC_ENABLE     0x04
#define INTC_ACTIVE     0x08
#define IRQ_UART        (1u << 0)
#define IRQ_WTIMER      (1u << 1)
#define IRQ_PMU         (1u << 2)
#define IRQ_EXT_WAKE    (1u << 3)

/* PMU */
#define PMU_CTRL        0x00
#define PMU_STATUS      0x04
#define PMU_DVFS        0x08
#define PMU_IRQ_EN      0x0C
#define PMU_SCRATCH0    0x10
#define PMU_SCRATCH1    0x14
#define PMU_WAKE_CAUSE  0x18
#define PMU_SLEEP_CNT   0x1C
#define PMU_VSEL        0x20

#define PMU_MODE_IDLE   0u
#define PMU_MODE_SLEEP  1u
#define PMU_MODE_DEEP   2u
#define PMU_CTRL_LP_EN  (1u << 8)

#define PMU_ST_STATE(s)   ((s) & 0x1Fu)
#define PMU_ST_CUR_OP(s)  (((s) >> 8) & 0x3u)
#define PMU_ST_DVFS_PEND  (1u << 10)
#define PMU_ST_RESUME     (1u << 16)
#define PMU_ST_RESUME_DEEP (1u << 17)
#define PMU_ST_DVFS_DONE  (1u << 18)
#define PMU_ST_ERR_DIRTY  (1u << 19)

#define WAKE_MEIP       (1u << 0)
#define WAKE_MTIP       (1u << 1)
#define WAKE_MSIP       (1u << 2)

#define PM_RESUME_MAGIC 0x5E5E0A0Au

/* wake timer */
#define WT_CTRL         0x00
#define WT_LOAD         0x04
#define WT_COUNT        0x08
#define WT_STATUS       0x0C

#ifndef __ASSEMBLER__
#include <stdint.h>
#define REG32(base, off) (*(volatile uint32_t *)((base) + (off)))
#endif

#endif
