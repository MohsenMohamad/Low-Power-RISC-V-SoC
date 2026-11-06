/*
 * Run-control mailbox of the debug application (fw/debug/dbg_app.c), in the
 * persistent RAM area (doc/BOOT_ABI.md: PERSIST_ADDR, kept across resume,
 * resume-rejected cold boots and watchdog resets, cleared at power-on),
 * accessed only through the uncached alias. Written by the bench through
 * the monitor (tools/bench) or by the application itself (the record of a
 * running test survives the watchdog reset of the hang test).
 */
#ifndef DBG_MBOX_H
#define DBG_MBOX_H

#include <stdint.h>
#include "handoff.h"

#define DBG_MBOX_MAGIC      0xDB6B0C5Eu
#define DBG_MBOX_ADDR       (PERSIST_ADDR + 0x100u)     /* RAM_BASE + 0x300 */

typedef struct {
    uint32_t magic;
    uint32_t seed;
    uint32_t test_id;
    uint32_t flags;                         /* DBG_F_*                    */
    uint32_t iters;
    uint32_t state;                         /* DBG_ST_*, written by the app */
    uint32_t rsvd[2];
} dbg_mbox_t;

#define DBG_ST_REQUEST      0u              /* written by the bench: run it */
#define DBG_ST_RUNNING      1u
#define DBG_ST_PASS         2u
#define DBG_ST_FAIL         3u

#define DBG_F_INJECT        (1u << 0)       /* random fault injection     */
#define DBG_F_QUIET         (1u << 1)       /* no per-iteration lines     */

/* test ids (boot argument bits 15:0, dbgrun <id>) */
#define DBG_T_STRESS        1u
#define DBG_T_DRV           2u
#define DBG_T_CRASH_ILLEGAL 3u
#define DBG_T_CRASH_MISALIGN 4u
#define DBG_T_HANG          5u
#define DBG_T_DIVTEST       6u

#define DBG_MBOX ((volatile dbg_mbox_t *)(uintptr_t)(DBG_MBOX_ADDR + RAM_UNCACHED_OFFSET))

#endif
