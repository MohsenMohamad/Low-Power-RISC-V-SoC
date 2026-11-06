# Debug and Validation Infrastructure — Specification

Normative for the debug blocks (doc/SPEC.md "Register maps"). Scope:
observability hardware (`rtl/debug/`), its verification (`verif/debug/`),
debug firmware (`fw/debug/`), host tools (`tools/dbg_decode.py`,
`tools/triage.py`, `tools/cov_merge.py`, `tools/bench/`). doc/SOC_REGMAP.md
holds the SoC memory map and interrupt numbers; doc/CPU_SOC_INTERFACE.md the
CPU-side observability ports. Where this document and doc/SPEC.md disagree,
doc/SPEC.md wins.

---

## 1. Overview

| Block       | Module       | Purpose                                                        |
|-------------|--------------|----------------------------------------------------------------|
| Trace buffer| `dbg_trace`  | Circular buffer of retired PC / instruction / timestamp, triggers, freeze |
| Event counters | `dbg_evcnt` | Cache hit/miss, stall cycles, time per power state, wake / DVFS counts |
| Error log   | `dbg_errlog` | Last exception, last power transition + result, sticky error status |
| Watchdog    | `dbg_wdt`    | Hang detection, logs to error log, requests PD_CPU reset        |
| Wrapper     | `dbg_subsys` | One AXI4-Lite port + 4 blocks + internal wiring; instantiated in `aon_subsys` (`u_dbg`) |

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
* use only the SoC technology wrappers (doc/SPEC.md): `tech_sync`
  (synchroniser), `rst_sync` (reset synchroniser, built on `tech_sync`) and
  `tech_ram_2c` (two-clock simple dual-port RAM, `rtl/tech/`).

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

doc/SPEC.md assigns the debug range `0x2000_8000`, 32 KB, not cacheable.
`aon_subsys` decodes `0x2000_8000`-`0x2000_BFFF` (16 KB) onto `dbg_subsys`,
which selects the block with `addr[13:12]`; the blocks decode `addr[11:0]`.

| Base          | Size  | Block        |
|---------------|-------|--------------|
| `0x2000_8000` | 4 KB  | `dbg_trace`  |
| `0x2000_9000` | 4 KB  | `dbg_evcnt`  |
| `0x2000_A000` | 4 KB  | `dbg_errlog` |
| `0x2000_B000` | 4 KB  | `dbg_wdt`    |
| `0x2000_C000` - `0x2000_FFFF` | 16 KB | reserved: SLVERR (unmapped, doc/SPEC.md) |

The base is one constant in each consumer: `DBG_BASE` in `fw/include/soc.h`
(firmware), `DBG_BASE` in `tools/bench/soc_map.py` (bench). Both are taken
from this table and from doc/SOC_REGMAP.md, which lists the debug range in the
SoC memory map. The blocks sit behind the AXI4-Lite interconnect in PD_AON
like every other AON slave: accessible from the CPU and, with the CPU off,
from nothing else (there is no second bus master).

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

## 4. Input / output ports and their SoC connections

`dbg_subsys` is instantiated in `aon_subsys` (`u_dbg`). Domain column: `cpu` =
synchronous to `clk_cpu`, from PD_CPU, isolated to 0 by `soc_top.u_iso` while
PD_CPU is isolated; `aon` = synchronous to `clk_aon`.

### 4.1 Common

| Port | Dir | Width | Domain | Connected to |
|------|-----|-------|--------|-------------|
| `clk_aon_i` | in | 1 | – | `clk_aon` |
| `rst_aon_ni` | in | 1 | async | AON reset (`soc_top.rst_aon_n`, from POR) |
| `clk_cpu_i` | in | 1 | – | `clk_cpu` (after the DVFS mux and the PMU clock gate) |
| `s_axil_*` | – | – | aon | interconnect slave 7 of `aon_subsys` (`0x2000_8000`, 16 KB), `ADDR_W=14` |

### 4.2 CPU retire / trap port

Driven by `cpu_top` (`dbg_ret_*`, `dbg_trap_*`; doc/CPU_SOC_INTERFACE.md
"Debug observability"), flop outputs, one `clk_cpu` cycle after the event.

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `ret_valid_i` | 1 | cpu | one instruction retired (committed and not trapped) |
| `ret_pc_i` | 32 | cpu | PC of the retired instruction |
| `ret_insn_i` | 32 | cpu | instruction word |
| `trap_valid_i` | 1 | cpu | a trap was taken: exception or interrupt entry |
| `trap_cause_i` | 32 | cpu | `mcause` value written by the trap (bit 31 = interrupt) |
| `trap_pc_i` | 32 | cpu | `mepc` value written by the trap |
| `trap_tval_i` | 32 | cpu | `mtval` value written by the trap |

Contract: `ret_valid_i` shall not be high in the cycle that follows
`trap_valid_i` (pipeline flush); the blocks also accept both in the same
cycle (older instruction retires while the trap is taken; trace order
retire, trap), which the in-house core never produces (asserted in
`cpu_top`: `a_dbg_ret_trap_excl`, `a_dbg_no_ret_after_trap`). The trace
testbench assumes the contract.

"Exception" below means a trap with `trap_cause_i[31] == 0`.

### 4.3 Cache / pipeline event port

Driven by `cpu_top` (`dbg_ic_*`, `dbg_dc_*`, `dbg_stall_o`; definitions in
doc/CPU_SOC_INTERFACE.md "Debug observability").

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `ic_hit_i` | 1 | cpu | I-cache lookup hit (one pulse per cacheable fetch lookup) |
| `ic_miss_i` | 1 | cpu | I-cache lookup miss |
| `dc_hit_i` | 1 | cpu | D-cache lookup hit (one pulse per cacheable load / store lookup) |
| `dc_miss_i` | 1 | cpu | D-cache lookup miss |
| `stall_i` | 1 | cpu | pipeline stall: a valid instruction is held in its stage this cycle |

### 4.4 Power port

Driven by the PMU (`pmu.dbg_*`, registered). The power state is the
*stable* state, derived from completed transitions, not from the PMU FSM
(audit B16 / W24):

| PMU event | `pwr_state_i` becomes | `pmu_evt_*` (from, to, result) |
|---|---|---|
| IDLE entry completed (`CLK_GATE -> IDLE`) | IDLE | RUN, IDLE, 0 OK |
| SLEEP / DEEP_SLEEP entry completed (`PWR_OFF -> OFF`) | SLEEP / DEEP_SLEEP | RUN, SLEEP / DEEP_SLEEP, 0 OK |
| power-down refused (`BUS_DRAIN -> IDLE`, `STATUS.ERR_DIRTY`) | IDLE | RUN, SLEEP / DEEP_SLEEP, 3 refused |
| entry aborted by a wake before the core acknowledged (`IDLE_REQ -> WAKE_REL`) | (stays RUN) | RUN, requested state, 2 aborted |
| wake completed (`WAKE_REL -> RUN` from IDLE, SLEEP or DEEP_SLEEP) | RUN | old state, RUN, 0 OK |

DVFS sequences run while the state is IDLE and do not change it; the
operating point changes when the sequence has completed (`CUR_OP`).

| Port | Width | Domain | Description |
|------|-------|--------|-------------|
| `pwr_state_i` | 2 | aon | stable CPU power state (§3.1) |
| `dvfs_op_i` | 2 | aon | current DVFS operating point (0..2, PMU `STATUS.CUR_OP`) |
| `pmu_evt_valid_i` | 1 | aon | one-cycle pulse when a power transition completes, is refused or is aborted |
| `pmu_evt_from_i` | 2 | aon | stable state before the transition |
| `pmu_evt_to_i` | 2 | aon | requested target state |
| `pmu_evt_result_i` | 2 | aon | 0 OK, 1 timeout (not produced: the PMU has no timeouts), 2 aborted (wake during entry), 3 refused (power-down condition not met, `ERR_DIRTY`) |

`pwr_state_i` changes at most once every 4 `clk_aon` cycles: asserted in the
PMU (`a_dbg_state_rate`) and proven with SymbiYosys (`make formal`), assumed
by the trace testbench. The event contract is asserted in the PMU
(`a_dbg_evt_complete`, `a_dbg_evt_refused`, `a_dbg_evt_abort`,
`a_dbg_evt_only`).

### 4.5 Block-to-block wiring (inside `dbg_subsys`)

| From | Port | To | Port | Meaning |
|------|------|----|------|---------|
| `dbg_errlog` | `freeze_o` | `dbg_trace`, `dbg_evcnt` | `freeze_i` | an enabled sticky error is set |
| `dbg_wdt` | `wdt_evt_o` | `dbg_errlog` | `wdt_evt_i` | watchdog bite, hold until ack |
| `dbg_errlog` | `wdt_evt_ack_o` | `dbg_wdt` | `wdt_evt_ack_i` | bite has been logged |
| `dbg_wdt` | `cpu_rst_req_o` | `dbg_errlog` | `wdt_rst_i` | reset was requested (for `WDT_RST` sticky bit) |

### 4.6 Outputs to the SoC

| Port | Block | Domain | Description |
|------|-------|--------|-------------|
| `cpu_rst_req_o` | wdt | aon | PD_CPU reset request, high for `RST_PULSE` (16) clk_aon cycles; PMU input `wdt_rst_req_i` (audit B17), which performs the reset from RUN, IDLE, SLEEP or DEEP_SLEEP (doc/SOC_REGMAP.md "Watchdog reset") |
| `wdt_irq_o` | wdt | aon | bark (pre-timeout) interrupt, level, cleared by `STATUS.BARK` W1C or kick; interrupt-controller source 5 (audit W23) |
| `err_irq_o` | errlog | aon | `|(STATUS & IRQ_EN)`, level; interrupt-controller source 4 (audit W23) |

---

## 5. Trace buffer — `dbg_trace` (base + 0x000)

Parameter `DEPTH` (power of 2, 16..128, default 64). Each entry is 4 words.

### 5.1 Registers

| Off | Name | Access | Reset | Description |
|-----|------|--------|-------|-------------|
| 0x000 | ID | RO | 0xDB600101 | |
| 0x004 | CTRL | RW | 0x00000068 | `[0] EN` capture enable; `[1] CLEAR` W1S (clears buffer, pointers, freeze, stop); `[2] FREEZE` W1S software freeze; `[3] LOG_TRAP` record trap entries; `[4] LOG_PWR` record power-change entries; `[5] FRZ_EXC` freeze on exception; `[6] FRZ_ERR` freeze when `freeze_i` is high |
| 0x008 | STATUS | RO | 0 | `[0] ACTIVE` capturing; `[1] FROZEN`; `[2] WRAPPED`; `[3] STOPPED` stop trigger hit; `[4] ARMED` enabled, waiting for start; `[5] CLR_PEND`; `[6] OVF` an entry was dropped (4-entry write FIFO full; cannot happen under the port contract) |
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
5. The PMU receives the request (`wdt_rst_req_i`), resets PD_CPU without
   cutting a bus transaction (doc/SOC_REGMAP.md "Watchdog reset"), sets
   `PMU.STATUS.WDT_RST`, and the boot ROM cold-boots with `rst_cause` WDT
   (doc/BOOT_ABI.md), keeping RAM, so the application restarts and can dump
   the error log, counters and trace (all in PD_AON, not reset) post mortem.

## 9. Firmware (`fw/debug/`)

Part of the one firmware tree (`fw/Makefile`, application `dbgapp`, image
`build/fw/lpsoc/dbgapp.hex`); GCC 13.2, `-march=rv32im_zicsr_zifencei
-mabi=ilp32`, `-Werror`. Shared with every other application, not copied:

* startup `fw/app/crt0.S`, boot ROM, image format (doc/BOOT_ABI.md);
* drivers: the debug blocks are `fw/drivers/dbg.c` (API in
  `fw/include/drivers.h`, registers in `fw/include/soc.h`), next to the UART,
  timer, intc, PMU and cache drivers; `cache_stats()` (cache statistics,
  doc/SPEC.md) reads the event counters;
* power management `fw/pm/pm.c`, platform, monitor, and the monitor commands
  `sleep` / `opp` / `exit` (`fw/app/app_cmds.c`, one implementation for the
  validation application and this one);
* result checking: `scripts/run_fw.py` + `scripts/check_results.py`.

`fw/debug` holds only the application (`dbg_app.c`), the crash handler and
dump (`dbg_crash.c`, section 10) and the divergence kernel
(`dbg_div_kernel.S`, plus its Spike harness `spike_divk.S`).

* Tests (boot-argument test id, or `dbgrun <id> <seed> [iters] [flags]`):
  1 stress (section 11), 2 driver and wiring test (trace triggers and freeze,
  retire / trap port against memory and mcause / mepc / mtval, exact D-cache
  hit / miss counts, I-cache events, stall counter, error-log and watchdog
  interrupts at intc sources 4 / 5, PMU stable state / transition events /
  time in state / DVFS count, trace intact across SLEEP), 3 illegal
  instruction (expected crash), 4 misaligned load (expected crash), 5 hang
  (watchdog reset of PD_CPU through the PMU, post-mortem dump after the
  reboot), 6 divergence kernel (trace compared with Spike).
* Run control: the host boot argument (doc/BOOT_ABI.md, bit 31 set) selects
  the test; host arguments 0..2 are seed, iterations, flags. The application
  prints `PASS` / `FAIL 0x...` and stops. On a board the bench writes the
  debug mailbox (`fw/include/dbg_mbox.h`, `RAM_BASE + 0x300` in the
  persistent area, uncached alias) with state REQUEST, or uses `dbgrun`.
  The mailbox record of a running test survives the watchdog reset, so the
  rebooted application knows the hang was expected.

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

The CRC-32 (IEEE) covers the bytes of every line from `BEGIN` up to the line before `END`, each terminated by `\n` (the console expands `\n` to `\r\n`; the decoder removes the `\r`). The decoder (`tools/dbg_decode.py`) flags a dump whose CRC does not match.

## 11. Random stress test

`fw/debug/dbg_app.c` (test 1): xorshift32 PRNG seeded from the run control
(host argument 0); the seed is printed first (`STRESS seed=0x...`). Each
iteration draws an operation: compute (two formulations of a mul/div/rem
kernel must agree), memory traffic (pattern write/readback, compared through
the uncached alias after a D-cache clean), cache maintenance (clean / flush /
I-cache invalidate through `mcachectl`, then buffer CRC), timer interrupt
(handler count), sleep / wake in IDLE, SLEEP or DEEP_SLEEP through
`pm_suspend` (wake by the machine timer, RAM CRC after wake), DVFS change
through `pm_set_opp`.

A sleep operation passes only if the requested transition completed:
`PM_WOKE` for IDLE, `PM_RESUMED` for SLEEP / DEEP_SLEEP, confirmed by the
PMU's IDLE_CNT / SLEEP_CNT advancing by one. An aborted transition
(`PM_ABORTED`) or any other result fails the run (doc/SPEC.md). The
state x operating-point coverage (`COV sleep_state=.. opp=..`) is recorded
only after the transition completed. Flag bit 2 (`DBG_F_NEG_ABORT`, negative
test `dbg-neg/stress-abort`) makes every sleep see an already pending wake;
the run must then fail.

All random decisions come from the PRNG, so a seed reproduces the run
exactly (the operation and coverage lines of two runs with the same seed are
compared, `dbg/stress-repro`); every iteration prints
`I <n> op=<name> arg=0x..`. The watchdog runs during the test (kicked per
iteration, paused in SLEEP / DEEP_SLEEP). The run ends with `COV ...`
functional-coverage lines and `STRESS PASS seed=...`, or a crash dump. Flag
bit 0: with probability 1/16 per iteration an illegal instruction,
misaligned load, load access fault or a hang is injected, to exercise the
crash path and triage.

## 12. Bench and monitor protocol

The bench (`tools/bench`) drives a target through main's UART monitor
(`fw/app/monitor.c`, `fw/app/main.c`, `fw/app/app_cmds.c`, the debug
application's `dbg` / `dbgrun`). All protocol details are in one module,
`tools/bench/monitor_adapter.py`; all addresses in `tools/bench/soc_map.py`
(from doc/SOC_REGMAP.md and this document); everything board-specific in
`tools/bench/board.py`.

* prompt `mon> ` (`zzz> ` before a UART-wake sleep); input is echoed; output
  lines end with `\r\n`; errors start with `ERR`
* `peek <addr> [n]` -> `0x%08x: 0x%08x` per word: the bench requires every
  line to carry the address it asked for; `poke <addr> <v>` -> `OK`;
  `regs <blk>`; `go <addr>`
* `sleep <idle|sleep|deep> <ticks|uart>` -> `woke: result r, rst_cause c,
  wake_cause w, sleep_cnt +n`, plus `ERR transition ABORTED|failed` when the
  transition did not complete; `opp <0..2>` -> `opp n`; `exit [code]`
* `dbg`, `dbgrun <t> <seed> [iters] [flags]` -> `DBGRUN RESULT: PASS|FAIL`
* stream alignment: the adapter first sends a lone line end and waits for a
  prompt (bytes typed while the target boots can overflow the 8-entry UART
  RX FIFO and lose the line end), then an unknown command with a unique
  marker, and waits for `ERR unknown command '<marker>'`.

There is no reset, load or checksum command. Loading
(`tools/bench/loader.py`): the image (doc/BOOT_ABI.md format) is checked on
the host, written with `poke` through the RAM's uncached alias
(`0x3000_0000`: no D-cache clean per word, no stale cached copy), read back
with `peek <addr> 64` and compared by CRC-32. A reboot is a watchdog reset
of PD_CPU (`Monitor.reboot`: the bench programs `dbg_wdt` with a short
timeout and RST_EN, section 8 and doc/SOC_REGMAP.md "Watchdog reset"); the
boot ROM then checks the image header CRC and starts the image.

Steps (`tools/bench/sequencer.py`, test list
`tools/bench/testlists/sim_demo.toml`): identity check (exact debug IDs;
the PMU has no ID register, so CTRL.LP_EN, STATUS state RUN, VSEL = CUR_OP
and the debug PSTATE are checked), firmware load, debug tests, forced
power-state transitions (the monitor's `sleep`; the step passes only if the
transition completed and the PMU counter, the debug transition / wake
counts, the time in the state and the error log's last transition all
agree), DVFS changes (PMU TARGET_OP written with `poke`, the monitor's `opp`
executes the WFI; CUR_OP, VSEL, debug DVFS count, PSTATE checked), expected
crash capture (dump decoded with `tools/dbg_decode.py`, then a reboot), a
final dump. Every received line is captured with a timestamp; per-step
artifacts and `results.json` (`tools/triage.py` format) plus
`results_check.json` (required list `dv/regress/bench.required`).

Simulation target (`tools/bench/sim_bridge.py`, `make bench`): the SoC
simulation `sim/tb_soc.sv` built with `-DBENCH_PTY` (`make bench-sim`)
connects the UART to a host pseudo-terminal
(`verif/debug/integ/dbg_uart_pty_bridge.sv`, `uart_pty.c`); it starts in
the boot ROM monitor with no image, exactly as a board after power-on.

## 13. Regression

Part of the single top-level `make test` (scripts/regress.py); each step
checks its results against a required-test list (doc/SPEC.md):

| Step | Command | Required list | Content |
|---|---|---|---|
| debug unit benches | `make dbg-unit` | `dv/regress/dbg_unit.required` | `verif/debug` benches (trace at depths 16 / 32 / 64 / 128, counters, error log, watchdog, wrapper) x `DBG_SEEDS`, and negative tests of the bench checkers (`scripts/run_dbg.py`) |
| debug on the SoC | `make dbg-integ` | `dv/regress/dbg_integ.required` | the debug application on `sim/tb_soc.sv` (`scripts/run_fw.py dbg`): wiring test, stress seeds, reproducibility, expected crashes, watchdog hang, Spike divergence, fault injection + triage |
| bench flow | `make bench` | `dv/regress/bench.required` | `tools/bench` against the simulation through the UART pseudo-terminal (section 12) |

`tools/dbg_decode.py` judges every crash dump (CRC, reason, mcause /
mtval, divergence against Spike), `tools/triage.py` groups the
fault-injection failures by signature and replays one;
`tools/cov_merge.py` merges the debug bench coverage. They are tools of
those steps, not runners of their own.

