/*
 * Debug subsystem register map (doc/DEBUG_SPEC.md).
 *
 * DBG_BASE: 0x4002_0000 in the SoC map proposal; 0x4F00_4000 in the PicoRV32
 * integration preview, where the subsystem hangs off the SoC external port
 * (verif/debug/integ). [MERGE] align with the SoC top.
 */
#ifndef DBG_REGS_H
#define DBG_REGS_H

#include <stdint.h>

#ifndef DBG_BASE
#define DBG_BASE            0x40020000u
#endif
#define DBG_TRACE_BASE      (DBG_BASE + 0x0000u)
#define DBG_EVCNT_BASE      (DBG_BASE + 0x1000u)
#define DBG_ERRLOG_BASE     (DBG_BASE + 0x2000u)
#define DBG_WDT_BASE        (DBG_BASE + 0x3000u)

#define DBG_REG(b, o)       (*(volatile uint32_t *)(uintptr_t)((b) + (o)))

#define DBG_ID_MAGIC        0xDB600000u
#define DBG_ID_TRACE        0xDB600101u
#define DBG_ID_EVCNT        0xDB600201u
#define DBG_ID_ERRLOG       0xDB600301u
#define DBG_ID_WDT          0xDB600401u
#define DBG_ID              0x000u

/* ---- trace buffer ---- */
#define TRC_CTRL            0x004u
#define TRC_STATUS          0x008u
#define TRC_TRIG            0x00Cu
#define TRC_START_PC        0x010u
#define TRC_STOP_PC         0x014u
#define TRC_PC_MASK         0x018u
#define TRC_WPTR            0x01Cu
#define TRC_COUNT           0x020u
#define TRC_DEPTH           0x024u
#define TRC_TOTAL           0x028u
#define TRC_TSTAMP          0x02Cu
#define TRC_ENTRY(i)        (0x800u + 16u * (i))
#define TRC_CTRL_EN         (1u << 0)
#define TRC_CTRL_CLEAR      (1u << 1)
#define TRC_CTRL_FREEZE     (1u << 2)
#define TRC_CTRL_LOG_TRAP   (1u << 3)
#define TRC_CTRL_LOG_PWR    (1u << 4)
#define TRC_CTRL_FRZ_EXC    (1u << 5)
#define TRC_CTRL_FRZ_ERR    (1u << 6)
#define TRC_ST_ACTIVE       (1u << 0)
#define TRC_ST_FROZEN       (1u << 1)
#define TRC_ST_WRAPPED      (1u << 2)
#define TRC_ST_STOPPED      (1u << 3)
#define TRC_ST_ARMED        (1u << 4)
#define TRC_TRIG_NONE       0u
#define TRC_TRIG_PC         1u
#define TRC_TRIG_EXC        2u
#define TRC_TRIG_PWR        3u
#define TRC_INFO_TYPE(x)    ((x) & 3u)
#define TRC_TYPE_RETIRE     0u
#define TRC_TYPE_TRAP       1u
#define TRC_TYPE_PWR        2u

/* ---- event counters ---- */
#define EVC_CTRL            0x004u
#define EVC_STATUS          0x008u
#define EVC_IC_HIT          0x010u
#define EVC_IC_MISS         0x014u
#define EVC_DC_HIT          0x018u
#define EVC_DC_MISS         0x01Cu
#define EVC_STALL           0x020u
#define EVC_WAKE            0x024u
#define EVC_DVFS            0x028u
#define EVC_TRANS           0x02Cu
#define EVC_T_LO(s)         (0x030u + 8u * (s))
#define EVC_T_HI(s)         (0x034u + 8u * (s))
#define EVC_PSTATE          0x050u
#define EVC_CTRL_FREEZE     (1u << 0)
#define EVC_CTRL_CLEAR      (1u << 1)
#define EVC_CTRL_FRZ_ERR    (1u << 2)

/* ---- error log ---- */
#define ERR_STATUS          0x004u
#define ERR_CTRL            0x008u
#define ERR_IRQ_EN          0x00Cu
#define ERR_FRZ_EN          0x010u
#define ERR_SW_ERR          0x014u
#define ERR_SW_CODE         0x018u
#define ERR_EXC_CAUSE       0x020u
#define ERR_EXC_PC          0x024u
#define ERR_EXC_TVAL        0x028u
#define ERR_EXC_TS          0x02Cu
#define ERR_EXC_CNT         0x030u
#define ERR_PWR_LAST        0x040u
#define ERR_PWR_TS          0x044u
#define ERR_PWR_ERR_LAST    0x048u
#define ERR_PWR_ERR_TS      0x04Cu
#define ERR_WDT_CNT         0x050u
#define ERR_WDT_TS          0x054u
#define ERR_WDT_PSTATE      0x058u
#define ERR_TSTAMP          0x05Cu
#define ERR_ST_EXC          (1u << 0)
#define ERR_ST_EXC_OVR      (1u << 1)
#define ERR_ST_PWR_ERR      (1u << 2)
#define ERR_ST_WDT_BITE     (1u << 3)
#define ERR_ST_WDT_RST      (1u << 4)
#define ERR_ST_SW_ERR       (1u << 5)
#define ERR_ST_ALL          0x3Fu

/* ---- watchdog ---- */
#define WDT_CTRL            0x004u
#define WDT_LOAD            0x008u
#define WDT_BARK            0x00Cu
#define WDT_COUNT           0x010u
#define WDT_KICK            0x014u
#define WDT_STATUS          0x018u
#define WDT_RST_CNT         0x01Cu
#define WDT_CTRL_EN         (1u << 0)
#define WDT_CTRL_BARK_EN    (1u << 1)
#define WDT_CTRL_RST_EN     (1u << 2)
#define WDT_CTRL_PAUSE_LP   (1u << 3)
#define WDT_CTRL_LOCK       (1u << 31)
#define WDT_KICK_KEY        0x5A5AA5A5u
#define WDT_ST_BARK         (1u << 0)
#define WDT_ST_BITE         (1u << 1)

#endif
