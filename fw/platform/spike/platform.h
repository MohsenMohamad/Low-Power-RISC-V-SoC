/* Platform: Spike ISA simulator (RAM at 0x8000_0000, CLINT, HTIF console/exit).
 * No SoC peripherals: tests that need them are skipped (capabilities). */
#ifndef PLATFORM_H
#define PLATFORM_H

#include "soc.h"

#define PLATFORM_NAME       "spike"
#define PLATFORM_HAS_SOC    0
#define RAM_BASE            0x80000000u
#define RAM_SIZE            0x00100000u

/* CLINT layout */
#define TIMER_BASE          0x02000000u
#define TIMER_MTIME         0xBFF8u
#define TIMER_MTIMECMP      0x4000u
#define TIMER_MSIP          0x0000u

#define AON_PERIOD_PS       1u
#define OP0_PERIOD_PS       1u
#define OP1_PERIOD_PS       1u
#define OP2_PERIOD_PS       1u

#endif
