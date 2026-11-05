# Test Plan

Every feature of `doc/SPEC.md` mapped to its tests, coverage points, owning
area and status. Areas: **CPU** (core, CSRs, Spike lockstep; Session 1),
**caches** (Session 1), **SoC/PMU** (SoC top, PMU, CDC, UPF; Session 2),
**firmware** (boot ROM, drivers, validation suite, monitor; Session 3),
**UVM** (`verif/uvm`, Session 4), **debug** (this area), **bench** (lab automation, this area).

Status: **planned** (not in the repository yet) / **implemented** (exists,
not run or not passing here) / **passing** (run in this environment, see
evidence). Statuses of other areas are what was observed when their branch
was merged here, not their own claims.

Last full regression (`tools/regress.py --unit-seeds 3 --seeds 8`): 55 tests,
54 pass, 1 fail (Session 3 `run_tests.py`: its Verilator lint step, see
section 1); debug RTL line coverage 93.1 %, toggle 54.5 %, 50 of 52 cover
properties hit (open: `c_ovf`, `c_stop_pwr`). Bench demo: 11/11 steps pass.

Evidence runs (2026-11-05, Verilator 5.054, Spike 1.1.1-dev, riscv64-unknown-elf-gcc 13.2 and clang 18):
`tools/regress.py` (debug suites + random stress seeds), `tools/run_tests.py`
(Session 3, through the regression runner), `tools/bench/sequencer.py` (bench demo).

How to run: `python3 tools/regress.py` (everything that runs on open-source
tools), `make -C verif/debug run-test TEST=<t> SEED=<n>`, `python3 tools/run_tests.py`.

## 1. Architecture

| Feature (SPEC.md) | Tests | Coverage points | Area | Status |
|---|---|---|---|---|
| RV32IM 5-stage pipeline, forwarding, hazard stalls, branch flush | Spike lockstep on random instruction streams; riscv-arch-test | per-instruction, hazard pairs, flush causes | CPU | planned (in-house core not in repository) |
| Machine-mode CSRs | Spike lockstep; fw tests 1 csr_counters, 2 csr_machine_regs, 3 csr_mip_pending | CSR read/write forms | CPU, firmware | firmware tests passing on Spike (--priv=M, MSU); tests 2/3 not applicable on PicoRV32 (skip); in-house core planned |
| Interrupts / exceptions | fw tests 10-16, 20-26; Spike lockstep | every mcause | CPU, firmware | passing on PicoRV32 SoC and Spike (14 access fault: Spike only) |
| WFI | fw tests 25, 41 | wake masked / unmasked | CPU, firmware | passing (PicoRV32 SoC) |
| I$/D$ 4 KB 2-way, write-back D$ | cache random traffic vs memory model, eviction/flush; fw tests 30-35 | hit/miss/evict/writeback per set/way | caches, firmware | fw tests passing (PicoRV32 bring-up caches); in-house caches planned |
| Fence / flush before power-down | fw tests 31, 46; debug stress op `flush` + RAM CRC after sleep | flush kinds | caches, firmware, debug | passing |
| AXI4-Lite interconnect | SVA protocol checker `verif/debug/common/dbg_axil_sva.sv` (debug slaves); interconnect TB | handshake orders, back-pressure, SLVERR | SoC/PMU, debug | debug slaves passing; interconnect planned |
| Boot ROM 16 KB, RAM 128 KB retained | fw tests 42/43/74 | cold/resume/no-image paths | firmware | passing |
| UART, mtime/mtimecmp, interrupt controller | fw tests 70-72, 20-24 | per register | firmware | passing |
| Tech-cell wrappers with generic models | lint; debug uses `dbg_sync`, `dbg_ram_2c` wrappers | - | SoC/PMU, debug | debug wrappers passing lint; SoC wrappers (`rtl/tech`) lint FAIL here: 4 SYNCASYNCNET warnings in `tc_rst_sync.sv` under Verilator 5.054 (Session 3 `make lint`) |

## 2. Power domains and clocks

| Feature | Tests | Coverage points | Area | Status |
|---|---|---|---|---|
| PD_AON / PD_CPU, asynchronous clk_aon / clk_cpu, synchronisers | CDC review, SVA on handshakes; debug blocks: random clock ratios per seed (1/6..6) in every debug TB | clock ratio bins | SoC/PMU, debug | debug passing; SoC CDC planned |
| RUN / IDLE / SLEEP / DEEP_SLEEP | fw tests 41-46, 60, 61; debug stress op `sleep`; bench `force-sleep`, `force-deep-sleep-at-op2`, `force-idle` | state x OPP matrix (fw test 61; stress `COV sleep_state x opp`) | firmware, SoC/PMU, debug, bench | passing |
| Power-down / wake sequence (save, flush, WFI, gate, iso, off; wake, power_good, reset, iso off, clock, resume) | PMU formal (SymbiYosys); OFF-state corruption model; fw 42/43/46 | every PMU transition | SoC/PMU, firmware | fw passing on PicoRV32 PMU; formal planned |
| DVFS 3 OPs, glitch-free mux, change only in IDLE | fw 50-52, 61; stress op `dvfs`; bench `force-dvfs-*` | OP->OP transitions | SoC/PMU, firmware, bench | passing |
| UPF for both domains | UPF-aware simulation / static check | - | SoC/PMU | planned |

## 3. Verification methodology items

| Feature | Tests | Area | Status |
|---|---|---|---|
| SVA for AXI4-Lite | `dbg_axil_sva` bound to all debug slaves and the wrapper | debug | passing |
| SVA for PMU sequencing, isolation clamps, CDC handshakes | PMU/CDC SVA | SoC/PMU | planned |
| Class-based constrained-random TBs, cover properties, Verilator --timing | `verif/debug/{trace,evcnt,errlog,wdt,subsys}` | debug | passing |
| UVM VIP (Xcelium/VCS/Questa) | `verif/uvm/` | UVM | planned (needs a commercial simulator; excluded from CI) |
| Spike lockstep (DPI) | random instruction streams | CPU | planned |
| riscv-arch-test | compliance suite | CPU | planned |
| Cache random traffic vs reference model | cache TB | caches | planned (fw test 33 passing on bring-up caches) |
| PMU formal (SymbiYosys), OFF-state corruption | formal | SoC/PMU | planned (OFF-state corruption model present in `pico_pd_cpu.sv`) |
| cocotb smoke regression | discovered by `tools/regress.py` (cocotb Makefiles) | all | planned (none in repository yet) |
| Python for regression / triage / coverage | `tools/regress.py`, `tools/triage.py`, `tools/cov_merge.py` | debug | passing |
| Verilator lint clean | `make -C rtl/debug lint` (debug); `make lint` (SoC) | debug, SoC/PMU | debug passing; SoC lint FAIL (see section 1) |

## 4. Firmware

| Feature | Tests | Area | Status |
|---|---|---|---|
| Boot ROM cold/resume detection, context restore | fw 40, 42-46, 74 | firmware | passing (PicoRV32) |
| Drivers UART, timer, intc, PMU, cache | fw 70-73, 30-35 | firmware | passing |
| Validation suite with pass/fail signature | `tools/run_tests.py` | firmware | passing except its lint step |
| Sleep/wake stress loops | fw 60; debug stress | firmware, debug | passing |
| UART monitor (peek/poke, run test by ID) | `platform/picorv32/tests/monitor_*.txt`; bench adapter | firmware, bench | passing |
| in-house core build (`lpsoc`/`rv32m`) | build only | firmware, debug | builds (gcc and clang), not executed: core not in repository |

## 5. Debug and validation infrastructure (this area)

| Feature (DEBUG_SPEC.md) | Tests | Coverage points | Status |
|---|---|---|---|
| Trace buffer: circular capture of PC/insn/timestamp | `trace_rand` (reference model, random clock ratios), `integ_drv`, `integ_divtest` | `c_wrap`, `c_fifo2`, `c_ret_trap` | passing |
| Trace triggers start/stop on PC, exception, power change | `trace_rand` random trigger configs; `dbg_trace_sva` `a_start*`, `a_stop`, `a_armed_wait`; `integ_drv` (PC start/stop on real CPU) | `c_start_{none,pc,exc,pwr}`, `c_stop_{pc,exc,pwr}` | passing; `c_stop_pwr` not hit by the 3-seed regression (stop on power change exercised only through the model); open |
| Trace freeze on error | `a_frz_exc`, `a_frz_err`, `a_frz_sticky`, `a_frz_no_new`; `subsys_wdt_chain`; `integ_drv`; `integ_hang` (frozen by watchdog, survives PD_CPU reset) | `c_frz_exc`, `c_frz_err` | passing |
| Trace readable with PD_CPU off | `trace_pwroff`, `integ_drv` ("trace intact across SLEEP") | - | passing |
| Event counters I$/D$ hit/miss, stall, time per state, wakes, DVFS | `evcnt_rand`, `evcnt_pwr` (cycle-exact AON model), `integ_drv`, bench power/DVFS steps | `c_wake_sleep`, `c_wake_dsleep`, `c_idle`, `c_dvfs_chg`, `c_clear_pend`, `c_ovf`, `c_frz_err` | passing; `c_ovf` (32-bit counter wrap) not reached in simulation: open, needs a directed test with a preloaded counter |
| Counter freeze / clear | `evcnt_rand`, `a_frozen_hold` | - | passing |
| Error log: last exception, power transition + result, sticky across sleep | `errlog_rand` (incl. power-off periods), `a_sticky`, `a_pwr_err`; `integ_crash_*` | `c_set`/`c_clr` per bit, `c_ovr`, `c_keep_first`, `c_res1..3` | passing |
| Watchdog: bark, bite, log then PD_CPU reset, pause in sleep, lock | `wdt_rand`, `wdt_lock` (cycle-exact model), SVA `a_log_first`, `a_rst_pulse`, `a_pause`, `a_lock*`, `a_rst_stops`; `subsys_wdt_chain`; `integ_hang` (real reboot) | `c_bite_ack`, `c_bite_to`, `c_rst`, `c_bark`, `c_paused`, `c_lock`, `c_rst_stop` | passing |
| Drivers (trace, counters, error log, watchdog) | `integ_drv` (17 checks on PicoRV32 SoC) | - | passing |
| Crash handler + parseable dump | `integ_crash_illegal`, `integ_crash_misalign`, `integ_hang`; `dbg_decode.py` CRC check | - | passing |
| Seeded random stress, reproducible | `integ_stress` x N seeds; same seed -> identical UART log (checked); fault injection (`--stress-flags 1`) | `COV op=*`, `COV sleep_state x opp` | passing |
| Regression runner (discovery, parallel, timeout, summary) | `tools/regress.py` | - | passing |
| Triage (signatures, failing seeds, replay) | `tools/triage.py` on fault-injected stress runs; `--replay` reproduces | - | passing |
| Dump decoder + Spike divergence | `integ_divtest` vs `spike --log-commits` (match), and with `+tap_corrupt_pc` (first divergence reported) | - | passing |
| Coverage merger | `tools/cov_merge.py` (Verilator .dat merged per source location, lcov, firmware COV lines) | - | passing |
| CI | `.github/workflows/debug-regression.yml` | - | implemented (not run here: needs GitHub Actions) |

## 6. Bench automation

| Feature | Tests | Status |
|---|---|---|
| Monitor protocol adapter (Session 3 protocol) | bench demo, all steps | passing against simulation |
| Firmware loading through the monitor with checksum | `load-dbgapp` (poke, peek read-back CRC, boot ROM header CRC) | passing against simulation |
| Lab sequencer: power / DVFS forcing, timestamped capture, crash capture, triage hand-off | `tools/bench/testlists/sim_demo.toml` | passing against simulation |
| Simulation bridge (pty) | `dbg_uart_pty_bridge` + `sim_bridge.py` | passing |
| Board adapter | `tools/bench/board.py` FPGA template | implemented (template; no board yet) |

## 7. Integration items for merge

* Debug blocks at `DBG_BASE = 0x4002_0000` on the SoC AXI interconnect, ports
  per DEBUG_SPEC section 4 (CPU retire/trap, cache events, PMU state/events,
  `cpu_rst_req_o` to the PMU, `irq_o` to the interrupt controller).
* Replace `dbg_sync` / `dbg_ram_2c` bodies with the SoC wrappers.
* Rerun `integ_*` tests on the in-house core (expected: exact trap causes
  instead of the PicoRV32 IRQ-bit mapping of the preview).
