"""Addresses used by the bench, transcribed from doc/SOC_REGMAP.md (SoC
memory map, PMU) and doc/DEBUG_SPEC.md (debug blocks); doc/BOOT_ABI.md for
the RAM layout. The only copy of these numbers on the host side."""
RAM_BASE = 0x1000_0000
RAM_SIZE = 0x0002_0000
RAM_ALIAS = 0x3000_0000            # uncached alias of the RAM (doc/SPEC.md)
APP_BASE = 0x1000_1000             # application image (doc/BOOT_ABI.md)
HANDOFF = RAM_BASE                 # handoff block; rst_cause at +0x08

PMU_BASE = 0x2000_3000
PMU = {"ctrl": 0x00, "status": 0x04, "dvfs": 0x08, "irq_en": 0x0C, "scratch0": 0x10, "scratch1": 0x14,
       "wake_cause": 0x18, "sleep_cnt": 0x1C, "vsel": 0x20, "wake_mask": 0x24, "idle_cnt": 0x28}
PMU_CTRL_LP_EN = 1 << 8            # reset value of CTRL is 0x100; firmware never clears LP_EN

DBG_BASE = 0x2000_8000
DBG_IDS = {0x0000: 0xDB600101, 0x1000: 0xDB600201, 0x2000: 0xDB600301, 0x3000: 0xDB600401}
EVC = {"wake": 0x1024, "dvfs": 0x1028, "trans": 0x102C, "pstate": 0x1050,
       "t_idle_lo": 0x1038, "t_sleep_lo": 0x1040, "t_dsleep_lo": 0x1048}
ERR = {"status": 0x2004, "pwr_last": 0x2040, "wdt_cnt": 0x2050}
TRC = {"status": 0x0008, "total": 0x0028}
WDT = {"ctrl": 0x3004, "load": 0x3008, "bark": 0x300C, "count": 0x3010, "kick": 0x3014, "status": 0x3018,
       "rst_cnt": 0x301C}
WDT_CTRL_EN, WDT_CTRL_RST_EN = 1 << 0, 1 << 2

# power-state encoding of the debug blocks and the error log's transition record
PS = {"run": 0, "idle": 1, "sleep": 2, "deep": 3}
RES_OK = 0

MBOX = RAM_ALIAS + 0x300           # debug mailbox (fw/include/dbg_mbox.h), uncached alias
MBOX_MAGIC = 0xDB6B0C5E
