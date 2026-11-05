/*
 * Boot ROM <-> application interface in retained RAM.
 *
 *   RAM_BASE + 0x000  handoff_t (ROM status, saved CPU context)
 *   RAM_BASE + 0x200  persistent area (accessed through the uncached alias
 *                     only; survives software reset and sleep)
 *   RAM_BASE + 0x400  boot ROM .bss and stack (up to RAM_BASE + 0x1000)
 *   RAM_BASE + 0x1000 application image (image_hdr_t first)
 */
#ifndef HANDOFF_H
#define HANDOFF_H

#ifndef __ASSEMBLER__
#include <stdint.h>
#endif
#include "platform.h"

#define HANDOFF_ADDR        (RAM_BASE + 0x000u)
#define PERSIST_ADDR        (RAM_BASE + 0x200u)
#define PERSIST_SIZE        0x200u
#define ROM_RAM_BASE        (RAM_BASE + 0x400u)
#define ROM_STACK_TOP       (RAM_BASE + 0x1000u)
#define APP_BASE            (RAM_BASE + 0x1000u)

/* Saved CPU context (written by pm_ctx_save, consumed by the boot ROM). */
#define CTX_MAGIC           0x31585443u     /* "CTX1" */
#define CTX_NREGS           16              /* ra sp gp tp s0..s11 */
#define CTX_NARCH           8
#define IMAGE_MAGIC         0x5041504C      /* "LPAP" */

#ifndef __ASSEMBLER__
typedef struct {
    uint32_t magic;                 /* CTX_MAGIC when valid             */
    uint32_t crc;                   /* CRC-32 of regs[] and arch[]      */
    uint32_t regs[CTX_NREGS];
    uint32_t arch[CTX_NARCH];       /* CPU-specific state, see arch/    */
} pm_ctx_t;

/* boot_status values written by the boot ROM */
enum {
    BOOT_COLD          = 1,         /* cold boot, image started          */
    BOOT_RESUMED       = 2,         /* context restored after wake       */
    BOOT_RESUME_BADCTX = 3,         /* wake, but context invalid -> cold */
    BOOT_NO_IMAGE      = 4,         /* no valid image, ROM monitor       */
};

typedef struct {
    uint32_t soft_mtvec;            /* 0x00 trap vector (PicoRV32 arch)  */
    uint32_t boot_status;           /* 0x04 */
    uint32_t rst_cause;             /* 0x08 PMU reset cause at boot      */
    uint32_t cold_boots;            /* 0x0C */
    uint32_t resumes;               /* 0x10 */
    uint32_t bad_resumes;           /* 0x14 */
    uint32_t rom_version;           /* 0x18 */
    uint32_t signature;             /* 0x1C last suite signature         */
    uint32_t rsvd[8];               /* 0x20 */
    pm_ctx_t ctx;                   /* 0x40 */
} handoff_t;

#define HANDOFF ((volatile handoff_t *)HANDOFF_ADDR)

/* Application image header (at APP_BASE). */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t load_addr;
    uint32_t size;                  /* bytes, including this header      */
    uint32_t entry;
    uint32_t crc;                   /* CRC-32 of bytes after the header  */
    uint32_t rsvd[2];
} image_hdr_t;
#endif

/* Offsets used from assembly */
#define HANDOFF_SOFT_MTVEC  0x00
#define CTX_OFF_REGS        8
#define CTX_OFF_ARCH        (8 + 4 * CTX_NREGS)

#endif
