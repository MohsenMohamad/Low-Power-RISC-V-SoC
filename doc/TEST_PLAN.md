# Test plan

Every feature of doc/SPEC.md mapped to the tests that check it, the
regression step that runs them, and their status on the integrated SoC
(stage 3, branch `stage3`). Steps are `make` targets; `make test` runs all
of them (scripts/regress.py, required list `dv/regress/top.required`), each
against its own required-test list in `dv/regress/`.

Status:

- **pass**: run here and in CI by `make test`, every required result
  passing (numbers in doc/INTEGRATION_REPORT.md "Stage 3", with the command
  that reproduces each).
- **partial**: run and passing, with a named gap (waiver or open item).
- **not run**: cannot run on open-source tools here (reason given).

## 1. Architecture

| Feature (doc/SPEC.md) | Tests | Step | Status |
|---|---|---|---|
| RV32IM 5-stage pipeline, forwarding, hazard stalls, branch flush | Spike lockstep on 200 random programs + 2 directed; riscv-arch-test 3.9.1 (I, M, Zifencei, privilege); CPU coverage plan (ISA bins, hazard / flush cover properties) | `cosim`, `archtest`, `coverage` | pass (1 coverage hole waived with reason: `cp_wb_error`, dv/coverage_waivers.txt) |
| Machine-mode CSRs, interrupts / exceptions, WFI | lockstep (exceptions, interrupts compared); arch-test privilege; validation suite tests 1-3, 10-16, 20-26, 41 on the SoC; Spike suite | `cosim`, `archtest`, `fw-suite`, `fw-spike` | pass |
| 4 KB 2-way I-cache, 4 KB 2-way write-back D-cache | cache unit benches (random traffic vs memory model, eviction storms, maintenance, write-back errors; 8 seeds each); suite tests 30-37 on the SoC | `cachetest`, `fw-suite` | pass |
| AXI4-Lite interconnect | protocol SVA in the demux / bridge / mux (SoC runs with SVA); debug-slave protocol checker `verif/debug/common/dbg_axil_sva.sv`; bus-error suite test 76 | `sim`, `fw-suite`, `dbg-unit` | pass |
| 16 KB boot ROM, 128 KB RAM (retained) | boot test, suite tests 40, 42-48, 74; resume with dirty data; RAM CRC after SLEEP / DEEP_SLEEP (debug stress test) | `boot`, `boot-x`, `fw-suite`, `dbg-integ` | pass |
| UART, machine timer, wake timer, interrupt controller, PMU | suite tests 70-76; monitor sessions; PMU unit bench | `fw-suite`, `fw-monitor`, `sim-pmu` | pass |
| Technology cells only through wrappers | lint (every RTL file, -Wall); debug blocks use `tech_sync`, `rst_sync`, `tech_ram_2c` | `lint` | pass |
| PicoRV32 not part of the design | `git grep -i picorv32` finds only doc/SPEC.md's rule and the reports | review | pass |

## 2. Address map

| Feature | Tests | Step | Status |
|---|---|---|---|
| ROM / RAM / peripheral bases, RAM uncached alias | boot test (alias), suite tests 35, 76, monitor sessions (peek / poke through both windows) | `boot`, `fw-suite`, `fw-monitor` | pass |
| Debug blocks at `0x2000_8000`, 32 KB (reserved upper 16 KB: SLVERR) | suite test 76 (IDs readable, `0x2000_C000` / `0x2000_FFFC` fault, unmapped debug offset faults, partial write faults); monitor sessions (`peek 0x20008000` / `0x2000b000` IDs, `peek 0x2000c000` fault); bench identity check | `fw-suite`, `fw-monitor`, `bench` | pass |
| Unmapped addresses return SLVERR | suite test 76, boot test | `fw-suite`, `boot` | pass |
| Reset vector, RAM base, cacheable ranges are parameters | lint of `soc_top` / `pd_cpu` parameters; co-simulation runs `cpu_top` with a different RAM window | `lint`, `cosim` | pass |

## 3. Register maps

| Feature | Tests | Step | Status |
|---|---|---|---|
| doc/SOC_REGMAP.md registers and access rules | suite tests 70-76 (incl. SLVERR on RO / partial writes, values kept); PMU unit bench (every PMU register against a reference model) | `fw-suite`, `sim-pmu` | pass |
| doc/DEBUG_SPEC.md registers | debug unit benches (every block against a reference model, SLVERR rules, config lock while enabled); debug driver / wiring test on the SoC | `dbg-unit`, `dbg-integ` | pass |

## 4. Cache maintenance

| Feature | Tests | Step | Status |
|---|---|---|---|
| Only `mcachectl`, no memory-mapped controller | suite tests 30-36 | `fw-suite` | pass |
| Clean / flush complete only after every write response; errors reported | D-cache bench phases 4a / 4b (failing write responses), mutants `dc_clean_on_error`, `dc_evict_err_lost` | `cachetest`, `mutation` | pass |
| Write-back error path in firmware | D-cache bench only: the SoC RAM never errors while the CPU runs | `cachetest` | partial (open item: not provokable at SoC level) |
| Cache statistics from the debug event counters | suite test 37 (exact D-cache hit / miss counts, I-cache events, `cache_stats()` equals the counters); cache benches check every hit / miss pulse against the reference model; debug wiring test | `fw-suite`, `cachetest`, `dbg-integ` | pass |

## 5. CPU <-> SoC interface

| Feature | Tests | Step | Status |
|---|---|---|---|
| idle_req / idle_ack / cache_clean handshake, power-down only with both | PMU SVA (`a_iso_on_bus_idle`, `a_gate_needs_handshake`) proven (k-induction); lockstep bench drives random handshakes with interrupt races; dirty-cache refusal (pm_test, boot test, suite) | `formal`, `cosim`, `sim`, `fw-suite` | pass |
| "Caches idle" never substitutes for cache_clean | D-cache bench `cache_clean` contract checks; mutant `dc_clean_during_evict` | `cachetest`, `mutation` | pass |
| WFI resumes on pending & enabled (mie) interrupts; WAKE_MASK | suite test 48; PMU unit bench masked-noise episodes; SVA `a_wake_masked`, `a_masked_holds` proven | `fw-suite`, `sim-pmu`, `formal` | pass |
| mtime export with a safe CDC | `cdc_snapshot` proof + cover; suite timer tests | `formal`, `fw-suite` | pass |
| Interrupts synchronized exactly once | review (doc/CPU_SOC_INTERFACE.md), OFF-state corruption runs | `sim` | pass |
| Debug observability ports (retire / trap, cache events, stall) | `cpu_top` SVA (retire / trap exclusive, no retire after trap, hit / miss exclusive); cache benches; debug wiring test (instruction words = memory, mcause / mepc / mtval for exception and interrupt, exact D-cache counts, stall counter) | `sim`, `cachetest`, `dbg-integ` | pass |

## 6. Power domains and clocks

| Feature | Tests | Step | Status |
|---|---|---|---|
| RUN / IDLE / SLEEP / DEEP_SLEEP, all transitions | pm_test (all 6 transitions, 23/24 PMU arcs), suite power tests 41-48, 50-52, 60-61; PMU unit bench (all arcs); formal cover | `sim`, `sim-x`, `fw-suite`, `sim-pmu`, `formal` | partial (IDLE_REQ -> WAKE_REL waived at SoC level, covered by unit bench and formal cover) |
| Power-down / wake sequencing, isolation, reset | PMU SVA proven; OFF-state corruption model (random and 4-state X); isolation negative test | `formal`, `sim`, `sim-x`, `sim-neg` | pass |
| DVFS: 3 operating points, glitch-free mux, change only in IDLE | `dvfs_mux` proof; suite tests 50-52; pm_test all 6 pairs; PMU SVA `a_dvfs_switch_gated` | `formal`, `fw-suite`, `sim` | pass |
| PMU debug interface: stable state, transition events, state rate (audit B16, W24) | PMU SVA `a_dbg_state_rate`, `a_dbg_evt_*`, `a_dbg_ps_*` (proven); debug unit benches; wiring test (wake / transition / DVFS counts, time in state, error-log event) | `formal`, `sim-pmu`, `dbg-unit`, `dbg-integ` | pass |
| Watchdog PD_CPU reset through the PMU (audit B17) | PMU SVA `a_wdt_*` (proven); PMU unit bench watchdog episodes from RUN (with retry on a busy bus), IDLE, SLEEP, DEEP_SLEEP; selftest mutants; SoC hang test (real reboot, boot ROM `rst_cause` WDT, post-mortem dump); bench reboot | `formal`, `sim-pmu`, `selftest`, `dbg-integ`, `bench` | pass |
| IEEE 1801 UPF | none | - | not run (no open-source UPF-aware tool; `upf/soc_top.upf` unchecked) |

## 7. Boot and resume ABI

| Feature | Tests | Step | Status |
|---|---|---|---|
| Context save layout, magic, CRC, image header, PMU scratch registers | boot test (CRC-rejected resume -> cold boot), suite tests 40-46, 74; fw-neg ROM image rejection (bad CRC, unaligned entry) | `boot`, `fw-suite`, `fw-neg` | pass |
| Watchdog cold boot (image unchanged, `rst_cause` WDT) | SoC hang test; bench load + watchdog reboot | `dbg-integ`, `bench` | pass |

## 8. Firmware

| Feature | Tests | Step | Status |
|---|---|---|---|
| Boot ROM cold / resume detection, context restore | boot test, suite | `boot`, `fw-suite` | pass |
| Drivers: UART, timers, intc, PMU, cache maintenance, debug blocks | suite tests 70-76, 37; debug wiring test (debug drivers, error-log / watchdog interrupts at intc sources 4 / 5) | `fw-suite`, `dbg-integ` | pass |
| Validation suite (self-checking) | 46 tests on the SoC, every test required; on Spike (`--priv=M`, `MSU`) | `fw-suite`, `fw-spike` | pass |
| Sleep / wake stress loops | suite test 60; debug stress test (4 seeds, transitions must complete) | `fw-suite`, `dbg-integ` | pass |
| UART monitor: peek / poke, run test by ID | scripted monitor sessions (application, boot ROM); bench flow through the pty | `fw-monitor`, `bench` | pass |

## 9. Verification methodology and rules

| Feature | Tests | Step | Status |
|---|---|---|---|
| SVA for AXI4-Lite, PMU sequencing, isolation, CDC | RTL SVA in every SoC simulation; debug AXI checker | `sim`, `dbg-unit` | pass |
| Class-based constrained-random SV benches, cover properties, Verilator --timing | cache benches, PMU unit bench, debug unit benches | `cachetest`, `sim-pmu`, `dbg-unit` | pass (debug cover properties 50 of 52 hit: `c_ovf`, `c_stop_pwr` open, see open items) |
| UVM VIP under verif/uvm on a commercial simulator | none (UVM branch not merged) | - | not run (needs Xcelium / VCS / Questa; not part of this stage) |
| CPU: Spike lockstep, riscv-arch-test | as section 1 | `cosim`, `archtest` | pass |
| Caches: random traffic vs reference model | as section 1 | `cachetest` | pass |
| PMU: formal + cover, OFF-state corruption, full transition coverage | as section 6 | `formal`, `sim`, `sim-x`, `sim-pmu` | pass |
| Python only for regression, triage, coverage merging | `scripts/`, `tools/triage.py`, `tools/dbg_decode.py`, `tools/cov_merge.py` used by `dbg-unit` / `dbg-integ` / `bench` | - | pass |
| Verilator lint clean | SoC, CPU, debug blocks at every trace depth | `lint` | pass |
| Nonzero exit on any failure at every level | every runner + check_results; selftest of the checkers | `selftest` | pass |
| Required-test lists, unknown / missing / skipped = failure | `scripts/check_results.py` for every step; selftest cases | `selftest` | pass |
| Aborted transitions never pass or count as coverage | SoC bench ABORTED reporting; `pm_idle` / `pm_suspend` results; debug stress / driver test; bench force-power; negative tests `fw-neg/soc-idle-abort`, `dbg-neg/stress-abort`, `dbg-neg/drv-abort`, `selftest/bench/power-aborted` | `sim`, `fw-neg`, `dbg-integ`, `selftest` | pass |
| Coverage holes fail unless waived | `check_soc_cov.py`, `cov_report.py` with waiver files | `sim`, `coverage` | pass |
| Mutation: survivors / build failures fail | `scripts/mutation.py` | `mutation` | pass |
| Every checker has a negative test | `make selftest` (incl. bench, dump decoder), `sim-neg`, `fw-neg`, debug bench negatives (`neg/trace_ts_zero`, `neg/axil_rst`), `dbg-neg/*` | `selftest`, `sim-neg`, `fw-neg`, `dbg-unit`, `dbg-integ` | pass |
| Every proof has a cover run | `scripts/run_formal.py` (each job paired) | `formal` | pass |
| Assertions not disabled by what they check | `dbg_axil_sva` `a_rst_valid` fixed (`disable iff (1'b0)`), negative test `neg/axil_rst` | `dbg-unit` | pass |
| Published numbers reproducible | commands next to every number in doc/INTEGRATION_REPORT.md | - | pass |
| One setup script, exact versions | `scripts/setup_toolchain.sh --check` | `toolchain` | pass |
| FPGA build | none | - | not run (later stage) |

## 10. Debug and validation infrastructure (doc/DEBUG_SPEC.md)

| Feature | Tests | Step | Status |
|---|---|---|---|
| Trace buffer: capture, triggers, freeze, readout with PD_CPU off, every depth (16 / 32 / 64 / 128) | `trace_rand_d*`, `trace_pwroff_d*` (reference model incl. timestamp windows), trace SVA; wiring test (PC triggers, freeze on exception, trap entries, intact across SLEEP); divergence test vs Spike | `dbg-unit`, `dbg-integ` | pass |
| Event counters (cache, stall, time per state, wakes, DVFS, transitions) | `evcnt_rand`, `evcnt_pwr`; wiring test; suite test 37; bench power / DVFS steps | `dbg-unit`, `dbg-integ`, `fw-suite`, `bench` | partial (32-bit counter overflow cover `c_ovf` not reached) |
| Error log (exception, power transition + result, watchdog, software errors, sticky) | `errlog_rand`; wiring test (exception records, SLEEP -> RUN event, interrupt source 4); crash dumps | `dbg-unit`, `dbg-integ` | pass |
| Watchdog (bark, bite, log, PD_CPU reset, pause, lock) | `wdt_rand`, `wdt_lock`, `subsys_wdt_chain`; wiring test (bark at source 5); hang test (real reset); bench reboot | `dbg-unit`, `dbg-integ`, `bench` | pass |
| Crash handler, dump format, decoder | expected-crash tests (dump decoded, CRC, mcause / mtval checked); hang post-mortem; decoder negative tests | `dbg-integ`, `selftest` | pass |
| Seeded random stress, reproducible | 4 seeds; same-seed reproducibility; fault-injection seeds + triage (signature groups, replay) | `dbg-integ` | pass |
| Bench automation through the monitor (load, power / DVFS forcing, crash capture) | `make bench` (12 steps) against the SoC simulation through the pty; bench negative tests | `bench`, `selftest` | pass |
