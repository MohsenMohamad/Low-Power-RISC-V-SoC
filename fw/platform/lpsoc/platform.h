/* Platform: the low-power SoC with the in-house RV32IM core (doc/SPEC.md). */
#ifndef PLATFORM_H
#define PLATFORM_H

#include "soc.h"

#define PLATFORM_NAME       "lpsoc"
#define PLATFORM_HAS_SOC    1
#define RAM_BASE            SOC_RAM_BASE
#define RAM_SIZE            SOC_RAM_SIZE

/* Machine timer (doc/SOC_REGMAP.md layout) */
#define TIMER_BASE          MTIMER_BASE
#define TIMER_MTIME         MTIME_LO
#define TIMER_MTIMECMP      MTIMECMP_LO
#define TIMER_MSIP          MSIP

/* Clock periods of the simulation testbench (sim/tb_soc.sv), used by the
 * DVFS frequency check: clk_aon (mtime tick) and clk_cpu at OP0/OP1/OP2. */
#ifndef AON_PERIOD_PS
#define AON_PERIOD_PS       41000u
#endif
#ifndef OP0_PERIOD_PS
#define OP0_PERIOD_PS       47000u
#endif
#ifndef OP1_PERIOD_PS
#define OP1_PERIOD_PS       23000u
#endif
#ifndef OP2_PERIOD_PS
#define OP2_PERIOD_PS       11000u
#endif

#endif
