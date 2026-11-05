/* Spike ISA simulator: RAM at 0x8000_0000, CLINT, HTIF console/exit. */
#ifndef PLATFORM_H
#define PLATFORM_H

#include "soc.h"

#define PLATFORM_NAME       "spike"
#define RAM_BASE            0x80000000u
#define RAM_SIZE            0x00100000u
#define CLINT_BASE          0x02000000u
#define PLATFORM_HAS_SOC    0

/* No PMU / DVFS on Spike; only referenced by tests that are skipped. */
#define AON_HZ              1u
#define REF_HZ              1u

#endif
