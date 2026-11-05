/* Low-power RISC-V SoC - memory map and register definitions. */
#ifndef SOC_H
#define SOC_H

/* Unsigned-constant helper usable from C and assembler. */
#ifdef __ASSEMBLER__
#define _U(x) x
#else
#define _U(x) x##u
#endif

#define ROM_BASE        _U(0x00000000)
#define RAM_BASE        _U(0x10000000)
#define RAM_SIZE        _U(0x00020000)
#define RAM_ALIAS_BASE  _U(0x30000000)   /* uncached alias of RAM (doc/SPEC.md) */
#define UART_BASE       _U(0x20000000)
#define MTIMER_BASE     _U(0x20001000)
#define INTC_BASE       _U(0x20002000)
#define PMU_BASE        _U(0x20003000)
#define WTIMER_BASE     _U(0x20004000)

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
#define IRQ_UART        (_U(1) << 0)
#define IRQ_WTIMER      (_U(1) << 1)
#define IRQ_PMU         (_U(1) << 2)
#define IRQ_EXT_WAKE    (_U(1) << 3)

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
#define PMU_CTRL_LP_EN  (_U(1) << 8)

#define PMU_ST_STATE(s)   ((s) & _U(0x1F))
#define PMU_ST_CUR_OP(s)  (((s) >> 8) & _U(0x3))
#define PMU_ST_DVFS_PEND  (_U(1) << 10)
#define PMU_ST_RESUME     (_U(1) << 16)
#define PMU_ST_RESUME_DEEP (_U(1) << 17)
#define PMU_ST_DVFS_DONE  (_U(1) << 18)
#define PMU_ST_ERR_DIRTY  (_U(1) << 19)

#define WAKE_MEIP       (_U(1) << 0)
#define WAKE_MTIP       (_U(1) << 1)
#define WAKE_MSIP       (_U(1) << 2)

#define PM_RESUME_MAGIC _U(0x5E5E0A0A)

/* CPU CSRs (in-house core, doc/CPU.md) */
#define CSR_MCACHECTL   0x7C0
#define MCACHECTL_DFLUSH  (_U(1) << 0)   /* D-cache clean + invalidate */
#define MCACHECTL_IINVAL  (_U(1) << 1)   /* I-cache invalidate */
#define MCACHECTL_DCLEAN  (_U(1) << 2)   /* D-cache clean */
#define MCACHECTL_WBERR   (_U(1) << 31)  /* write-back error (read) */
#define MIE_MSIE        (_U(1) << 3)
#define MIE_MTIE        (_U(1) << 7)
#define MIE_MEIE        (_U(1) << 11)
#define MSTATUS_MIE     (_U(1) << 3)

/* wake timer */
#define WT_CTRL         0x00
#define WT_LOAD         0x04
#define WT_COUNT        0x08
#define WT_STATUS       0x0C

#ifndef __ASSEMBLER__
#include <stdint.h>
#define REG32(base, off) (*(volatile uint32_t *)((base) + (off)))
/* Uncached view of a RAM object (bypasses the D-cache). */
#define RAM_ALIAS(p)    ((uintptr_t)(p) - RAM_BASE + RAM_ALIAS_BASE)
#endif

#endif
