/*
 * CPU abstraction: arch/rv32m, standard machine-mode CSRs (in-house core,
 * Spike). Interrupt and exception codes follow the RISC-V mcause encoding.
 */
#ifndef ARCH_H
#define ARCH_H

#include <stdint.h>

#define IRQ_MSI         3u
#define IRQ_MTI         7u
#define IRQ_MEI         11u
#define CAUSE_IRQ_FLAG  0x80000000u

#define EXC_INSN_MISALIGNED  0u
#define EXC_INSN_FAULT       1u
#define EXC_ILLEGAL          2u
#define EXC_BREAKPOINT       3u
#define EXC_LOAD_MISALIGNED  4u
#define EXC_LOAD_FAULT       5u
#define EXC_STORE_MISALIGNED 6u
#define EXC_STORE_FAULT      7u
#define EXC_ECALL_M          11u

/* Capability bits provided by the CPU (combined with platform caps). */
#define CAP_MCSR        (1u << 0)   /* standard M-mode CSR file           */
#define CAP_COUNTERS    (1u << 1)   /* cycle / instret counters           */
#define CAP_MISALIGN    (1u << 2)   /* misaligned load/store traps        */
#define CAP_ACCFAULT    (1u << 3)   /* access-fault exceptions            */

void     arch_init(void);           /* install trap entry                 */
uint32_t arch_caps(void);

/* Global interrupt enable (mstatus.MIE equivalent). */
uint32_t arch_irq_save(void);       /* disable, return previous state     */
void     arch_irq_restore(uint32_t state);
void     arch_irq_global_enable(void);
/* Per-source enable (mie equivalent), code = IRQ_MSI/IRQ_MTI/IRQ_MEI. */
void     arch_irq_enable(uint32_t code);
void     arch_irq_disable(uint32_t code);
int      arch_irq_is_enabled(uint32_t code);
/* mie as a whole: wake-source mask (bits 1 << IRQ_*), save/replace/restore */
uint32_t arch_irq_wake_sources(void);
uint32_t arch_irq_mask_save(uint32_t new_mask);
void     arch_irq_mask_restore(uint32_t old_mask);

void     arch_wfi(void);
uint64_t arch_cycles(void);
uint64_t arch_instret(void);

#endif
