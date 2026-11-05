# Debug and Validation Infrastructure — Specification

Scope: observability hardware (`rtl/debug/`), its verification (`verif/debug/`),
debug firmware (`fw/debug/`), host automation (`tools/`), CI
(`.github/workflows/`). This document is the contract that the other areas
(CPU, SoC top/PMU, boot ROM/drivers/monitor, UVM) connect to at merge.

Items marked **[MERGE]** are assumptions that must be aligned with the owning
area when branches are merged.

---

## 1. Overview

| Block       | Module       | Purpose                                                        |
|-------------|--------------|----------------------------------------------------------------|
| Trace buffer| `dbg_trace`  | Circular buffer of retired PC / instruction / timestamp, triggers, freeze |
| Event counters | `dbg_evcnt` | Cache hit/miss, stall cycles, time per power state, wake / DVFS counts |
| Error log   | `dbg_errlog` | Last exception, last power transition + result, sticky error status |
| Watchdog    | `dbg_wdt`    | Hang detection, logs to error log, requests PD_CPU reset        |
| Wrapper     | `dbg_subsys` | Optional: one AXI4-Lite port + 4 blocks + internal wiring       |

All four blocks:

* are standalone AXI4-Lite slaves (each has its own port, 12-bit address = 4 KB page);
* sit in **PD_AON** and are reset only by the AON power-on reset `rst_aon_ni`,
  never by the PD_CPU reset, so their state survives IDLE, SLEEP, DEEP_SLEEP and
  watchdog-initiated PD_CPU resets;
* have their register/AXI side in the `clk_aon` domain. Blocks that observe
  PD_CPU signals (`dbg_trace`, `dbg_evcnt`, `dbg_errlog`) contain a small
  capture front end clocked by `clk_cpu` (the flops are AON-powered; when
  PD_CPU is off `clk_cpu` is gated and the PD_CPU outputs are clamped to 0 by
  the isolation cells, so the front end is simply idle);
* contain their own reset synchronisers (async assert, sync de-assert) per clock;
* use only the `dbg_sync` (2-flop synchroniser) and `dbg_ram_2c` (two-clock
  simple dual-port RAM) wrappers for technology cells. **[MERGE]** these wrapper
  bodies are replaced by the SoC-wide synchroniser / RAM wrappers of the SoC
  top area; the port lists are kept.

### 1.1 Clock-domain crossings (all inside the blocks)

| Crossing | Mechanism |
|----------|-----------|
| AON timestamp → clk_cpu (trace timestamps) | free-running Gray counter, 2-FF sync, Gray→binary |
| Counters / write count clk_cpu → AON | Gray-coded counters, 2-FF sync; display held while a clear is in flight |
| Enable / freeze levels AON → clk_cpu | 2-FF level sync |
| Clear AON → clk_cpu | toggle request / toggle acknowledge (`CLR_PEND` status bit) |
| Power-state events AON → clk_cpu (trace) | 4-bit Gray event counter + quasi-static state/timestamp registers |
| Exception record clk_cpu → AON (error log) | data held stable in a clk_cpu register + toggle request / ack |
| Trace RAM | write port `clk_cpu`, read port `clk_aon` (`dbg_ram_2c`) |
| Configuration registers AON → clk_cpu | quasi-static: writable only while the block is disabled (SLVERR otherwise) |

---

## 2. Memory map

`SPEC.md` does not assign addresses. The debug subsystem uses a range that is
not used by any other block in the current proposals:

| Base          | Size  | Block        |
|---------------|-------|--------------|
| `0x5000_0000` | 4 KB  | `dbg_trace`  |
| `0x5000_1000` | 4 KB  | `dbg_evcnt`  |
| `0x5000_2000` | 4 KB  | `dbg_errlog` |
| `0x5000_3000` | 4 KB  | `dbg_wdt`    |
| `0x5000_4000` – `0x5000_FFFF` | 48 KB | reserved for debug |

**[MERGE]** the base is a single constant: `DBG_BASE` in
`fw/debug/include/dbg_regs.h` and `--dbg-base` / `soc_map.py` in
`tools/bench/`. If the SoC top area places the subsystem elsewhere only those
two constants change. The blocks decode only `addr[11:0]`; `dbg_subsys`
decodes `addr[13:12]`.

### 2.1 Platform map used by the simulation stand-ins (testbench only)

The firmware and bench demo run on `verif/debug/plat/` (Spike + Verilated debug
RTL + stand-in UART/PMU/timer). The stand-in addresses below exist only in that
platform and in `fw/debug/include/platform.h` (**[MERGE]** replaced by the SoC
map and the Session 3 drivers):

| Base          | Device (stand-in)                         |
|---------------|-------------------------------------------|
| `0x0200_0000` | machine timer: `mtime` +0xBFF8, `mtimecmp` +0x4000 (CLINT layout) |
| `0x1000_0000` | UART (`DATA` +0, `STATUS` +4: bit0 tx_busy, bit1 rx_valid; `CTRL` +8: bit0 rx irq enable) |
| `0x1000_1000` | PMU stand-in (see §8.4)                   |
| `0x1000_2000` | simulation control (`EXIT` +0: write `code<<1 | 1`) |
| `0x5000_0000` | debug subsystem (real RTL)                |
| `0x8000_0000` | RAM, 128 KB                               |

---

## 3. Common register conventions

* 32-bit registers, 32-bit accesses only. A write with `WSTRB != 4'b1111`, an
  access to an unmapped offset, or a write to a locked/read-only register
  returns **SLVERR** and has no effect. Reads of unmapped offsets return 0 with SLVERR.
* Offset `0x000` of every block is `ID` (RO): `[31:16]=0xDB60`, `[15:8]=block`
  (1 trace, 2 evcnt, 3 errlog, 4 wdt), `[7:0]=version (0x01)`.
* `W1C` = write 1 to clear, `W1S` = write 1 to perform an action (self-clearing).
* Every block has its own free-running 32-bit AON timestamp counter `TSTAMP`
  (clk_aon cycles since AON reset). All blocks reset together, so their
  timestamps are identical and can be correlated.

### 3.1 Power-state encoding (input `pwr_state_i[1:0]`)

| Value | State      |
|-------|------------|
| 0     | RUN        |
| 1     | IDLE       |
| 2     | SLEEP      |
| 3     | DEEP_SLEEP |

---

## 4. Input / output ports (connected at merge)

Domain column: `cpu` = synchronous to `clk_cpu`, from PD_CPU (must be isolated
to 0 when PD_CPU is off); `aon` = synchronous to `clk_aon`.

### 4.1 Common

| Port | Dir | Width | Domain | Description |
|------|-----|-------|--------|-------------|
| `clk_aon_i` | in | 1 | – | AON clock (AXI and registers) |
| `rst_aon_ni` | in | 1 | async | AON power-on reset, active low |
| `clk_cpu_i` | in | 1 | – | PD_CPU clock after DVFS mux / gate (trace, evcnt, errlog) |
| `s_axil_*` | – | – | aon | AXI4-Lite slave, `ADDR_W=12`, 32-bit data |

### 4.2 CPU retire / trap port (from the CPU, Session 1) **[MERGE]**

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `ret_valid_i` | 1 | cpu | one instruction retired this cycle |
| `ret_pc_i` | 32 | cpu | PC of the retired instruction |
| `ret_insn_i` | 32 | cpu | instruction word (16-bit encodings zero-extended) |
| `trap_valid_i` | 1 | cpu | a trap is taken this cycle |
| `trap_cause_i` | 32 | cpu | `mcause` value written by the trap (bit 31 = interrupt) |
| `trap_pc_i` | 32 | cpu | `mepc` value written by the trap |
| `trap_tval_i` | 32 | cpu | `mtval` value written by the trap |

Contract: `ret_valid_i` and `trap_valid_i` may be high in the same cycle
(older instruction retires while the trap is taken); `ret_valid_i` shall not be
high in the cycle that follows `trap_valid_i` (pipeline flush). This is
checked by an SVA assumption in the trace testbench.

"Exception" below means a trap with `trap_cause_i[31] == 0`.

### 4.3 Cache / pipeline event port (from CPU + caches, Session 1) **[MERGE]**

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `ic_hit_i` | 1 | cpu | I-cache lookup hit (one pulse per lookup) |
| `ic_miss_i` | 1 | cpu | I-cache lookup miss |
| `dc_hit_i` | 1 | cpu | D-cache lookup hit |
| `dc_miss_i` | 1 | cpu | D-cache lookup miss |
| `stall_i` | 1 | cpu | pipeline stalled this cycle (any reason) |

### 4.4 Power port (from the PMU, Session 2) **[MERGE]**

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `pwr_state_i` | 2 | aon | current CPU power state (§3.1) |
| `dvfs_op_i` | 2 | aon | current DVFS operating point (0..2) |
| `pmu_evt_valid_i` | 1 | aon | one-cycle pulse when a power transition completes or fails |
| `pmu_evt_from_i` | 2 | aon | state before the transition |
| `pmu_evt_to_i` | 2 | aon | requested target state |
| `pmu_evt_result_i` | 2 | aon | 0 OK, 1 timeout (e.g. no `power_good`), 2 aborted (wake during entry), 3 sequencing error |

Requirement: `pwr_state_i` changes at most once every 4 `clk_aon` cycles
(PMU sequencing is far slower; assumed in the trace testbench).

### 4.5 Block-to-block wiring (done inside `dbg_subsys`, or at the SoC top)

| From | Port | To | Port | Meaning |
|------|------|----|------|---------|
| `dbg_errlog` | `freeze_o` | `dbg_trace`, `dbg_evcnt` | `freeze_i` | an enabled sticky error is set |
| `dbg_wdt` | `wdt_evt_o` | `dbg_errlog` | `wdt_evt_i` | watchdog bite, hold until ack |
| `dbg_errlog` | `wdt_evt_ack_o` | `dbg_wdt` | `wdt_evt_ack_i` | bite has been logged |
| `dbg_wdt` | `cpu_rst_req_o` | `dbg_errlog` | `wdt_rst_i` | reset was requested (for `WDT_RST` sticky bit) |

### 4.6 Outputs to the SoC

| Port | Block | Domain | Description |
|------|-------|--------|-------------|
| `cpu_rst_req_o` | wdt | aon | PD_CPU reset request, high for `RST_PULSE` (16) clk_aon cycles. **[MERGE]** PMU performs the reset (and powers PD_CPU on if needed). |
| `irq_o` | wdt | aon | bark (pre-timeout) interrupt, level, cleared by `STATUS.BARK` W1C or kick |
| `irq_o` | errlog | aon | `|(STATUS & IRQ_EN)`, level |

---

## 5. Trace buffer — `dbg_trace` (base + 0x000)

Parameter `DEPTH` (power of 2, 16..128, default 64). Each entry is 4 words.

### 5.1 Registers

| Off | Name | Access | Reset | Description |
|-----|------|--------|-------|-------------|
| 0x000 | ID | RO | 0xDB600101 | |
| 0x004 | CTRL | RW | 0x00000068 | `[0] EN` capture enable; `[1] CLEAR` W1S (clears buffer, pointers, freeze, stop); `[2] FREEZE` W1S software freeze; `[3] LOG_TRAP` record trap entries; `[4] LOG_PWR` record power-change entries; `[5] FRZ_EXC` freeze on exception; `[6] FRZ_ERR` freeze when `freeze_i` is high |
| 0x008 | STATUS | RO | 0 | `[0] ACTIVE` capturing; `[1] FROZEN`; `[2] WRAPPED`; `[3] STOPPED` stop trigger hit; `[4] ARMED` enabled, waiting for start; `[5] CLR_PEND` |
| 0x00C | TRIG | RW* | 0 | `[1:0] START_SEL`, `[5:4] STOP_SEL`: 0 none (start: immediately on EN; stop: never), 1 PC match, 2 exception, 3 power-state change |
| 0x010 | START_PC | RW* | 0 | start PC compare value |
| 0x014 | STOP_PC | RW* | 0 | stop PC compare value |
| 0x018 | PC_MASK | RW* | 0xFFFFFFFF | bits that take part in both PC compares |
| 0x01C | WPTR | RO | 0 | index of the next entry to be written |
| 0x020 | COUNT | RO | 0 | number of valid entries (≤ DEPTH) |
| 0x024 | DEPTH | RO | DEPTH | |
| 0x028 | TOTAL | RO | 0 | entries written since the last CLEAR (wraps at 2^32) |
| 0x02C | TSTAMP | RO | – | current AON timestamp |
| 0x800 + 16·i | ENTRY[i].PC | RO | | |
| 0x804 + 16·i | ENTRY[i].DATA | RO | | retire: instruction; trap: `mtval`; power: 0 |
| 0x808 + 16·i | ENTRY[i].TS | RO | | AON timestamp when written |
| 0x80C + 16·i | ENTRY[i].INFO | RO | | `[1:0] TYPE` (0 retire, 1 trap, 2 power), `[3:2] PSTATE` (power entry: new state), `[23:16] CAUSE[7:0]`, `[31] CAUSE[31]` (interrupt) |

`RW*`: writes are accepted only while `CTRL.EN=0`; otherwise SLVERR and no effect.
Entries at `i ≥ DEPTH` read as 0.

### 5.2 Behaviour

* Capture state machine (clk_cpu domain): `IDLE` → (`EN`) → `ARMED` → (start
  condition) → `ACTIVE` → (stop condition) → `STOPPED`. `START_SEL=0` goes from
  `ARMED` to `ACTIVE` immediately. Clearing `EN` returns to `IDLE` and keeps the
  buffer contents. The instruction / event that fires the start trigger is
  recorded; the one that fires the stop trigger is recorded and is the last entry.
* PC match: `(ret_pc_i & PC_MASK) == (START_PC & PC_MASK)` on a retire (resp.
  `STOP_PC`). Exception: `trap_valid_i && !trap_cause_i[31]`. Power-state change:
  any change of `pwr_state_i` (detected in clk_aon, forwarded to clk_cpu with a
  Gray event counter). Because `clk_cpu` is gated while the CPU sleeps, a
  power-state trigger takes effect before the next retired instruction.
* In `ACTIVE` each retire writes one entry, each trap (if `LOG_TRAP`) one entry,
  each power-state change (if `LOG_PWR`) one entry. The buffer is circular:
  after `DEPTH` entries the oldest is overwritten and `WRAPPED` is set.
* Freeze: on an exception with `FRZ_EXC=1` (after the trap entry is written),
  on `freeze_i` with `FRZ_ERR=1`, or on `CTRL.FREEZE`. A frozen buffer accepts
  no writes until `CLEAR`. Freeze is sticky across `EN` changes.
* Readout: oldest entry is `WRAPPED ? WPTR : 0`, newest is `WPTR-1 (mod DEPTH)`.
  Read the buffer only while it is frozen, stopped or disabled; an entry being
  written in the same clk_aon cycle may read inconsistent data.
* PD_CPU off: the RAM and all state are AON-powered and clocked for reads by
  `clk_aon`, so the full buffer is readable while PD_CPU is off. Isolated
  (clamped) inputs produce no writes.

---

## 6. Event counters — `dbg_evcnt` (base + 0x1000)

| Off | Name | Access | Reset | Description |
|-----|------|--------|-------|-------------|
| 0x000 | ID | RO | 0xDB600201 | |
| 0x004 | CTRL | RW | 0 | `[0] FREEZE` (level: counters hold); `[1] CLEAR` W1S (all counters to 0); `[2] FRZ_ERR` hold while `freeze_i` is high |
| 0x008 | STATUS | RO/W1C | 0 | `[0] FROZEN` (effective); `[1] CLR_PEND`; `[12:8] OVF` W1C overflow flags of IC_HIT, IC_MISS, DC_HIT, DC_MISS, STALL |
| 0x010 | IC_HIT | RO | 0 | clk_cpu domain, 32-bit |
| 0x014 | IC_MISS | RO | 0 | |
| 0x018 | DC_HIT | RO | 0 | |
| 0x01C | DC_MISS | RO | 0 | |
| 0x020 | STALL | RO | 0 | stall cycles |
| 0x024 | WAKE_CNT | RO | 0 | transitions SLEEP or DEEP_SLEEP → RUN |
| 0x028 | DVFS_CNT | RO | 0 | changes of `dvfs_op_i` |
| 0x02C | TRANS_CNT | RO | 0 | any change of `pwr_state_i` |
| 0x030/0x034 | T_RUN_LO/HI | RO | 0 | clk_aon cycles spent in RUN (64-bit) |
| 0x038/0x03C | T_IDLE_LO/HI | RO | 0 | |
| 0x040/0x044 | T_SLEEP_LO/HI | RO | 0 | |
| 0x048/0x04C | T_DSLEEP_LO/HI | RO | 0 | |
| 0x050 | PSTATE | RO | – | `[1:0]` current power state, `[5:4]` current DVFS point |

* Cycle and instret counts are **not** duplicated: they are the CPU's standard
  `mcycle`/`minstret` CSRs (the crash dump reads them directly).
* 64-bit reads: reading `*_LO` latches the matching `*_HI` into a shadow so the
  pair is coherent. Read LO first.
* The five clk_cpu counters are Gray-coded and synchronised into clk_aon; the
  read value lags by 2–3 clk_aon cycles. A `CLEAR` is applied in clk_cpu by a
  toggle handshake; while `CLR_PEND=1` (and 2 cycles after) the AON copies are
  held. If `clk_cpu` is gated the clear stays pending until it runs.
* FREEZE / `freeze_i` hold all counters, including time-in-state.

---

## 7. Error / crash log — `dbg_errlog` (base + 0x2000)

| Off | Name | Access | Reset | Description |
|-----|------|--------|-------|-------------|
| 0x000 | ID | RO | 0xDB600301 | |
| 0x004 | STATUS | W1C sticky | 0 | `[0] EXC` exception logged; `[1] EXC_OVR` exception dropped (one already in flight); `[2] PWR_ERR` a power transition reported a non-OK result; `[3] WDT_BITE`; `[4] WDT_RST` watchdog requested a PD_CPU reset; `[5] SW_ERR` |
| 0x008 | CTRL | RW | 0 | `[0] KEEP_FIRST` keep the first exception record until EXC is cleared (default: record the last) |
| 0x00C | IRQ_EN | RW | 0 | STATUS bits that raise `irq_o` |
| 0x010 | FRZ_EN | RW | 0x1C | STATUS bits that raise `freeze_o` (default PWR_ERR, WDT_BITE, WDT_RST) |
| 0x014 | SW_ERR | WO | – | write: set `STATUS.SW_ERR`, store value in SW_CODE |
| 0x018 | SW_CODE | RO | 0 | |
| 0x020 | EXC_CAUSE | RO | 0 | `mcause` of the logged exception |
| 0x024 | EXC_PC | RO | 0 | `mepc` |
| 0x028 | EXC_TVAL | RO | 0 | `mtval` |
| 0x02C | EXC_TS | RO | 0 | AON timestamp when logged |
| 0x030 | EXC_CNT | RO | 0 | exceptions seen (saturating) |
| 0x040 | PWR_LAST | RO | 0 | `[1:0] FROM`, `[3:2] TO`, `[5:4] RESULT`, `[31:16]` transitions seen (saturating) |
| 0x044 | PWR_TS | RO | 0 | timestamp of the last transition |
| 0x048 | PWR_ERR_LAST | RO | 0 | same format as PWR_LAST, last failing transition |
| 0x04C | PWR_ERR_TS | RO | 0 | |
| 0x050 | WDT_CNT | RO | 0 | watchdog bites logged |
| 0x054 | WDT_TS | RO | 0 | timestamp of the last bite |
| 0x058 | WDT_PSTATE | RO | 0 | `pwr_state_i` at the last bite |
| 0x05C | TSTAMP | RO | – | current AON timestamp |

* Everything is reset only by `rst_aon_ni`: the sticky status survives SLEEP,
  DEEP_SLEEP and watchdog PD_CPU resets. Firmware checks `STATUS` at boot.
* Exceptions are captured in clk_cpu into a held register and transferred with
  a toggle handshake; an exception that arrives while a transfer is in flight
  (≈ 5 cycles) is counted as `EXC_OVR` instead of being recorded.
* `wdt_evt_i` is acknowledged (`wdt_evt_ack_o`) in the cycle after it is logged.

---

## 8. Watchdog — `dbg_wdt` (base + 0x3000)

| Off | Name | Access | Reset | Description |
|-----|------|--------|-------|-------------|
| 0x000 | ID | RO | 0xDB600401 | |
| 0x004 | CTRL | RW (lockable) | 0x8 | `[0] EN`; `[1] BARK_EN` bark interrupt; `[2] RST_EN` request PD_CPU reset on bite; `[3] PAUSE_LP` pause in SLEEP / DEEP_SLEEP; `[31] LOCK` (set-only; CTRL/LOAD/BARK become read-only until AON reset) |
| 0x008 | LOAD | RW (lockable) | 0xFFFFFFFF | timeout in clk_aon cycles, reloaded on kick, enable and after a bite |
| 0x00C | BARK | RW (lockable) | 0 | bark when `COUNT ≤ BARK` (pre-timeout interrupt) |
| 0x010 | COUNT | RO | – | current down-counter |
| 0x014 | KICK | WO | – | write `0x5A5AA5A5` to reload; any other value sets `BAD_KICK` and is ignored |
| 0x018 | STATUS | RO/W1C | 0 | `[0] BARK` W1C; `[1] BITE` W1C; `[2] RST_PEND` (RO) reset request active; `[3] BAD_KICK` W1C; `[4] LOG_WAIT` (RO) waiting for the error-log ack |
| 0x01C | RST_CNT | RO | 0 | number of PD_CPU reset requests issued |

Bite sequence when `COUNT` reaches 0 with `EN=1`:

1. `STATUS.BITE` set, `wdt_evt_o` raised and held (state `LOG_WAIT`).
2. When `wdt_evt_ack_i` is seen (or after 64 cycles if the error log does not
   answer), `wdt_evt_o` drops.
3. If `RST_EN=1`, `cpu_rst_req_o` is high for 16 clk_aon cycles and `RST_CNT`
   increments. The reset request is never raised before the bite was logged
   (SVA-checked).
4. `COUNT` reloads from `LOAD`. After a reset request `EN` is cleared, so the
   rebooting software (boot ROM included, which does not know the watchdog)
   starts with the watchdog stopped and re-arms it; with `LOCK=1` the watchdog
   keeps running instead and the boot code must kick it. Without `RST_EN`
   (log only) counting continues.

### 8.4 PMU stand-in used by the platform simulation (testbench only)

Not part of the debug hardware; documented here because the debug firmware and
bench demo use it. **[MERGE]** replaced by the real PMU and its driver.

| Off | Name | Description |
|-----|------|-------------|
| 0x00 | REQ | `[1:0]` state to enter on the next WFI (0 = stay in RUN/IDLE gating only) |
| 0x04 | DVFS | `[1:0]` requested operating point, applied at the next IDLE entry |
| 0x08 | STATE | `[1:0]` current state, `[5:4]` current DVFS point |
| 0x0C | FAULT | `[1:0]` result to report for the next transition (fault injection) |
| 0x10 | WAKE_CNT | wakes performed |

---

## 9. Firmware (`fw/debug/`)

* `include/dbg_regs.h` – register map (this document); `drivers/` – trace,
  counters, error log, watchdog drivers (only these four).
* `crash/` – crash handler and fixed-format dump (§10).
* `stress/` – seeded random stress test (§11).
* `platform/` – `soc` (weak hooks bound to the Session 3 drivers at merge) and
  `plat` (stand-ins of the simulation platform).
* `monitor_shim/` – **simulation stand-in only**, implements exactly the
  assumed monitor command subset of §12 so the bench can be demonstrated. It is
  deleted at merge and the Session 3 monitor is used.
* Toolchain: `riscv64-unknown-elf-gcc` if present, else `clang --target=riscv32`
  + `ld.lld`; `-march=rv32im_zicsr -mabi=ilp32`. Override with `TOOLCHAIN=gcc|clang`.

Seed / mailbox: a 32-byte mailbox at `RAM_BASE + 0x1FF00` (`MBOX_MAGIC`
`0xDB6B0C5E`, `SEED`, `TEST_ID`, `FLAGS`, `ITER`). The loader (platform sim,
bench or debugger) writes it before starting an image. **[MERGE]** align the
address with the RAM map.

## 10. Crash dump format (UART, fixed and parseable)

Line oriented, ASCII, `\n` terminated, hexadecimal values with `0x` prefix, no
other output interleaved between `BEGIN` and `END`:

```
### DBG-CRASH BEGIN v1
REASON <exception|watchdog|bark|software|boot-sticky|pwr-err>
SEED 0x<seed>
CSR mcause=0x.. mepc=0x.. mtval=0x.. mstatus=0x.. mcycle=0x<64b> minstret=0x<64b>
ERRLOG status=0x.. exc_cause=0x.. exc_pc=0x.. exc_tval=0x.. exc_ts=0x.. exc_cnt=0x.. pwr_last=0x.. pwr_ts=0x.. pwr_err_last=0x.. wdt_cnt=0x.. wdt_ts=0x.. wdt_pstate=0x.. sw_code=0x..
COUNTERS ic_hit=0x.. ic_miss=0x.. dc_hit=0x.. dc_miss=0x.. stall=0x.. wake=0x.. dvfs=0x.. trans=0x.. t_run=0x.. t_idle=0x.. t_sleep=0x.. t_dsleep=0x.. pstate=0x..
TRACE status=0x.. count=<n> wptr=<n> depth=<n> total=0x..
T <idx> pc=0x.. data=0x.. ts=0x.. info=0x..      (oldest first, n lines)
### DBG-CRASH END crc=0x<crc32 of all lines from BEGIN to the line before END>
```

The decoder (`tools/dbg_decode.py`) rejects a dump whose CRC does not match.

## 11. Random stress test

`fw/debug/stress/`: xorshift32 PRNG seeded from the mailbox; the seed is
printed first (`STRESS seed=0x...`). Each iteration draws an operation:
compute (checked against a precomputed result), memory traffic (pattern
write/readback across RAM, checked), cache flush (`fence`/`fence.i` + driver
hook), interrupt (timer interrupt, handler count checked), sleep/wake in IDLE,
SLEEP or DEEP_SLEEP (via the PMU hook, wake by timer), DVFS change (applied in
IDLE). Every random decision comes only from the PRNG, so the same seed gives
the same sequence; each iteration prints `I <n> op=<name> arg=0x..`, so two
runs can be diffed. Ends with `STRESS PASS seed=... iters=...` or a crash dump.
Optional fault injection (`FLAGS` bit 0): with a probability of 1/64 per
iteration an illegal instruction, misaligned load, load access fault or hang
(watchdog) is injected, to exercise the crash path and triage.

## 12. Bench protocol adapter — assumed monitor commands **[MERGE: to be aligned with the monitor at merge]**

SPEC.md says only "memory/register peek/poke, run test by ID". The Session 3
monitor sources are not on this branch, so all protocol details live in one
module, `tools/bench/monitor_adapter.py`. The bench never builds a protocol of
its own. The minimal assumed command set (line based, `\r` or `\n` terminated,
prompt `> ` after every response):

| Command | Response | Use |
|---------|----------|-----|
| `r <addr>` | `<value hex>` | peek 32-bit |
| `w <addr> <value>` | `ok` | poke 32-bit |
| `t <id>` | test output, then a line containing `PASS` or `FAIL` | run test by ID |
| `c <addr> <len>` (optional) | `<crc32 hex>` | checksum; if missing, the adapter verifies by read-back |
| `g <addr>` (optional) | – | start a loaded image; if missing, the adapter uses `t` with the image ID |

Numbers are hexadecimal with optional `0x`. Errors print a line starting with `err`.

## 13. Regression conventions

`tools/regress.py` discovers suites from `tools/regress_suites.toml`:

* any directory with a Makefile that has a `list-tests` target is run per test
  (`make -C dir list-tests` prints names; `make -C dir run-test TEST=<name> SEED=<n>`);
* otherwise a Makefile with a `test` target is run as one test;
* cocotb smoke directories (Makefile including `cocotb-config --makefiles`) are
  run with `make SIM=verilator` and their `results.xml` is parsed;
* `verif/uvm/` is excluded (commercial simulator).

A test passes when its command exits 0 and its log contains no line matching
`(?i)^\s*(%?error|fatal|.*\bFAIL\b)`. Coverage files (`coverage*.dat`,
`*.info`) found in a test's directory are collected by `tools/cov_merge.py`.
