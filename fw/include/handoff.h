/*
 * Boot ROM <-> application ABI (doc/BOOT_ABI.md is normative; keep in sync).
 *
 * RAM layout (offsets from RAM_BASE):
 *   0x000  handoff_t: ROM status, counters, saved CPU context (pm_ctx_t at 0x040)
 *   0x100  host mailbox (written by the host / testbench, never by the ROM)
 *   0x200  persistent area: kept across resume and resume-rejected cold boots,
 *          cleared at power-on; accessed only through the uncached alias
 *   0x400  boot ROM .data / .bss / stack (up to 0x1000)
 *   0x1000 application image (image_hdr_t first), then .bss; stack at the top
 *
 * Resume (all must hold, otherwise cold boot):
 *   PMU.STATUS.RESUME = 1, PMU.SCRATCH1 = RESUME_MAGIC, PMU.SCRATCH0 = CTX_ADDR,
 *   ctx.magic = CTX_MAGIC, ctx.crc = CRC-32 over ctx.regs[] and ctx.arch[].
 */
#ifndef HANDOFF_H
#define HANDOFF_H

#ifndef __ASSEMBLER__
#include <stdint.h>
#endif
#include "platform.h"

#define HANDOFF_ADDR        (RAM_BASE + 0x000u)
#define CTX_ADDR            (RAM_BASE + 0x040u)
#define HOSTBOX_ADDR        (RAM_BASE + 0x100u)
#define PERSIST_ADDR        (RAM_BASE + 0x200u)
#define PERSIST_SIZE        0x200u
#define ROM_RAM_BASE        (RAM_BASE + 0x400u)
#define ROM_STACK_TOP       (RAM_BASE + 0x1000u)
#define APP_BASE            (RAM_BASE + 0x1000u)

#define RESUME_MAGIC        0x5E5E0A0Au     /* PMU.SCRATCH1 */
#define CTX_MAGIC           0x31585443u     /* "CTX1" */
#define CTX_NREGS           16              /* ra sp gp tp s0..s11 */
#define CTX_NARCH           8               /* mstatus mie mtvec mscratch, 4 x 0 */
#define CTX_SIZE            (8 + 4 * (CTX_NREGS + CTX_NARCH))
#define IMAGE_MAGIC         0x5041504Cu     /* "LPAP" */
#define IMAGE_VERSION       1u
#define IMAGE_HDR_SIZE      32u
#define HOSTBOX_MAGIC       0x48415247u     /* "HARG" */
#define ROM_VERSION         0x00020000u     /* 2.0: doc/BOOT_ABI.md */

/* boot_status values written by the boot ROM */
#define BOOT_COLD           1u      /* power-on cold boot, image started     */
#define BOOT_RESUMED        2u      /* context restored after SLEEP/DEEP     */
#define BOOT_RESUME_BADCTX  3u      /* woke from SLEEP/DEEP, context rejected */
#define BOOT_NO_IMAGE       4u      /* no valid image: ROM monitor           */

/* rst_cause values recorded by the boot ROM (from PMU.STATUS at entry) */
#define RST_POR             1u      /* STATUS.RESUME = 0 */
#define RST_SLEEP           2u      /* RESUME = 1, RESUME_DEEP = 0 */
#define RST_DEEP            3u      /* RESUME = 1, RESUME_DEEP = 1 */
#define RST_WDT             4u      /* STATUS.WDT_RST = 1: PD_CPU reset by the watchdog */

/* boot_reason: first resume check that failed (0 = resumed) */
#define REASON_OK           0u
#define REASON_NO_RESUME    1u      /* STATUS.RESUME = 0 (power-on)  */
#define REASON_MAGIC        2u      /* SCRATCH1 != RESUME_MAGIC      */
#define REASON_POINTER      3u      /* SCRATCH0 != CTX_ADDR          */
#define REASON_CTX_MAGIC    4u      /* ctx.magic != CTX_MAGIC        */
#define REASON_CRC          5u      /* ctx.crc mismatch              */

/* Offsets used from assembly */
#define CTX_OFF_MAGIC       0
#define CTX_OFF_CRC         4
#define CTX_OFF_REGS        8
#define CTX_OFF_ARCH        (8 + 4 * CTX_NREGS)

#ifndef __ASSEMBLER__
typedef struct {
    uint32_t magic;                 /* CTX_MAGIC when valid              */
    uint32_t crc;                   /* CRC-32 of regs[] and arch[]       */
    uint32_t regs[CTX_NREGS];
    uint32_t arch[CTX_NARCH];
} pm_ctx_t;

typedef struct {
    uint32_t rom_version;           /* 0x00 */
    uint32_t boot_status;           /* 0x04 BOOT_*                       */
    uint32_t rst_cause;             /* 0x08 RST_*                        */
    uint32_t boot_reason;           /* 0x0C REASON_*                     */
    uint32_t pmu_status;            /* 0x10 PMU.STATUS at ROM entry      */
    uint32_t cold_boots;            /* 0x14 */
    uint32_t resumes;               /* 0x18 */
    uint32_t bad_resumes;           /* 0x1C */
    uint32_t signature;             /* 0x20 last suite signature         */
    uint32_t rsvd[7];               /* 0x24 */
    pm_ctx_t ctx;                   /* 0x40 (CTX_ADDR)                   */
} handoff_t;

typedef struct {
    uint32_t magic;                 /* HOSTBOX_MAGIC when valid          */
    uint32_t boot_arg;              /* see platform_api.h BOOTARG_*      */
    uint32_t arg[3];                /* application arguments (0 if unset) */
} hostbox_t;

/* Application image header (at APP_BASE). */
typedef struct {
    uint32_t magic;                 /* IMAGE_MAGIC                       */
    uint32_t version;               /* IMAGE_VERSION                     */
    uint32_t load_addr;             /* APP_BASE                          */
    uint32_t size;                  /* bytes, including this header      */
    uint32_t entry;                 /* inside the image, 4-byte aligned  */
    uint32_t crc;                   /* CRC-32 of bytes after the header  */
    uint32_t rsvd[2];               /* 0                                 */
} image_hdr_t;

#define HANDOFF ((volatile handoff_t *)HANDOFF_ADDR)

_Static_assert(sizeof(pm_ctx_t) == CTX_SIZE, "pm_ctx_t layout");
_Static_assert(sizeof(handoff_t) == 0x40 + CTX_SIZE, "handoff_t layout");
_Static_assert(sizeof(image_hdr_t) == IMAGE_HDR_SIZE, "image_hdr_t layout");
#endif

#endif
