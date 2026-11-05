/*
 * Run-control mailbox written by the loader (bench through the monitor) or
 * provided by the integration testbench. Lives in the persistent RAM area
 * of the Session 3 layout (handoff.h: PERSIST_ADDR + 0x100), accessed only
 * through the uncached alias. [MERGE] align with the RAM map.
 */
#ifndef DBG_MBOX_H
#define DBG_MBOX_H

#include <stdint.h>

#define DBG_MBOX_MAGIC      0xDB6B0C5Eu
#define DBG_MBOX_OFFSET     0x300u          /* from RAM_BASE              */

typedef struct {
    uint32_t magic;
    uint32_t seed;
    uint32_t test_id;
    uint32_t flags;                         /* DBG_F_*                    */
    uint32_t iters;
    uint32_t state;                         /* written by the app         */
    uint32_t rsvd[2];
} dbg_mbox_t;

#define DBG_F_INJECT        (1u << 0)       /* random fault injection     */
#define DBG_F_QUIET         (1u << 1)       /* no per-iteration lines     */

/* test ids */
#define DBG_T_STRESS        1u
#define DBG_T_DRV           2u
#define DBG_T_CRASH_ILLEGAL 3u
#define DBG_T_CRASH_MISALIGN 4u
#define DBG_T_HANG          5u
#define DBG_T_DIVTEST       6u

/* Integration-testbench extension of the simulation control device. */
#define SIMCTRL_SEED        0x10u
#define SIMCTRL_FLAGS       0x14u
#define SIMCTRL_ITERS       0x18u
#define SIMCTRL_DBG_MAGIC   0x1Cu           /* reads DBG_MBOX_MAGIC       */

#endif
