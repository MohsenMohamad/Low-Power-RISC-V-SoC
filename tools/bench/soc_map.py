"""Addresses used by the bench (lpsoc map, doc/firmware.md + DEBUG_SPEC.md).
[MERGE] DBG_BASE is 0x4F00_4000 on the PicoRV32 integration preview (debug
blocks on the external port) and 0x4002_0000 in the SoC proposal."""
RAM_BASE = 0x2000_0000
APP_BASE = 0x2000_1000
PMU_BASE = 0x4000_2000
PMU = {"ctrl": 0x00, "status": 0x04, "wake_en": 0x08, "dvfs_op": 0x0C, "rst_cause": 0x10,
       "cnt_idle": 0x20, "cnt_sleep": 0x24, "cnt_deep": 0x28, "cnt_dvfs": 0x2C, "cnt_abort": 0x30,
       "off_time": 0x34, "wake_src": 0x38, "id": 0x3C}
DBG_BASE_PREVIEW = 0x4F00_4000
DBG_BASE_SOC = 0x4002_0000
DBG_IDS = {0x0000: 0xDB600101, 0x1000: 0xDB600201, 0x2000: 0xDB600301, 0x3000: 0xDB600401}
EVC = {"wake": 0x1024, "dvfs": 0x1028, "trans": 0x102C, "pstate": 0x1050,
       "t_sleep_lo": 0x1040, "t_dsleep_lo": 0x1048}
ERR = {"status": 0x2004, "pwr_last": 0x2040, "wdt_cnt": 0x2050}
TRC = {"status": 0x0008, "total": 0x0028}
MBOX = RAM_BASE + 0x300           # fw/debug/include/dbg_mbox.h (uncached alias +0x1000_0000)
MBOX_MAGIC = 0xDB6B0C5E
