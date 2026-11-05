/* Low-power SoC (in-house core or PicoRV32 bring-up version). */
#ifndef PLATFORM_H
#define PLATFORM_H

#include "soc.h"

#define PLATFORM_NAME       "lpsoc"
#define RAM_BASE            RAM_BASE_LPSOC
#define RAM_SIZE            RAM_SIZE_LPSOC
#define CLINT_BASE          CLINT_BASE_LPSOC
#define PLATFORM_HAS_SOC    1

/* Clock frequencies; defaults match the simulation testbench. */
#ifndef AON_HZ
#define AON_HZ              32258065u       /* clk_aon, mtime tick         */
#endif
#ifndef REF_HZ
#define REF_HZ              100000000u      /* DVFS reference, OP0         */
#endif

#endif
