#ifndef CSR_H
#define CSR_H

#include <stdint.h>

#define csr_read(csr) ({ uint32_t __v; __asm__ volatile("csrr %0, " #csr : "=r"(__v)); __v; })
#define csr_write(csr, val) __asm__ volatile("csrw " #csr ", %0" :: "rK"((uint32_t)(val)) : "memory")
#define csr_set(csr, val) ({ uint32_t __v; __asm__ volatile("csrrs %0, " #csr ", %1" : "=r"(__v) : "rK"((uint32_t)(val)) : "memory"); __v; })
#define csr_clear(csr, val) ({ uint32_t __v; __asm__ volatile("csrrc %0, " #csr ", %1" : "=r"(__v) : "rK"((uint32_t)(val)) : "memory"); __v; })
#define csr_swap(csr, val) ({ uint32_t __v; __asm__ volatile("csrrw %0, " #csr ", %1" : "=r"(__v) : "rK"((uint32_t)(val)) : "memory"); __v; })

#ifndef MSTATUS_MIE
#define MSTATUS_MIE   (1u << 3)
#endif
#define MSTATUS_MPIE  (1u << 7)
#define MSTATUS_MPP   (3u << 11)
#define MIP_MSIP      (1u << 3)
#define MIP_MTIP      (1u << 7)
#define MIP_MEIP      (1u << 11)

#endif
