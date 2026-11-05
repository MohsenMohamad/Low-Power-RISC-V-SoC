# Integration report

Branch `integration`, created from `main` (`4849878`). doc/SPEC.md is normative;
finding IDs (Bxx, Wxx, Cxx) refer to doc/reviews/interface_audit.md.

## Stage 1: SoC + in-house CPU

### What was merged

| Branch | Head merged | Content |
|---|---|---|
| `claude/nifty-rubin-f0g24y` (SoC) | `97cffe2` | SoC top, AON peripherals, PMU, CDC (AXI bridge, async FIFO), DVFS clock mux, tech wrappers, UPF, SVA, SymbiYosys proofs, OFF-state corruption model, SoC and PMU testbenches, firmware |
| `claude/elegant-brahmagupta-58k8yj` (CPU) | `806e9c0` | RV32IM 5-stage core, 4 KB 2-way I-cache, 4 KB 2-way write-back D-cache, AXI4-Lite mux, Spike lockstep co-simulation, riscv-arch-test 3.9.1 flow, cache unit benches, coverage report, mutation analysis |

No other branch was merged. Merge commits: `cdfd24d` (SoC), `8849b15` (CPU).

### What was removed

- `third_party/picorv32/` and `rtl/cpu/cpu_core_picorv32.sv` (the PicoRV32
  stand-in and its WFI-emulating wrapper). doc/SPEC.md: the PicoRV32 platform
  is not part of the design and may not be used as a test target. No file in
  the integrated tree references it.
- `scripts/setup_tools.sh` (CPU branch), replaced by the single
  `scripts/setup_toolchain.sh` (doc/SPEC.md "Toolchain").
- The SoC bench's built-in exemption of two PMU arcs ("not reachable with
  PicoRV32"); coverage holes now go through goal and waiver files.
- The PicoRV32 lint waivers in `lint/verilator.vlt`.

### Conflicts and how doc/SPEC.md decided them

Git conflicts were only add/add on `.gitignore` (union), `Makefile` and
`README.md` (both rewritten for the integrated tree). Neither branch changed
doc/SPEC.md, so main's version stayed. The interface conflicts:

| # | Conflict | SoC branch | CPU branch | Decision (doc/SPEC.md) | Where |
|---|---|---|---|---|---|
| 1 | RAM base / cacheable range (B01, W01) | RAM `0x1000_0000` | caches `0x8000_0000` | Address map: RAM `0x1000_0000`, ROM `0x0000_0000`, both cacheable (ROM I-side). Reset vector, RAM base and cacheable ranges are `soc_top` parameters passed to `pd_cpu`; `cpu_top` defaults changed to the SPEC map. The CPU-only co-simulation keeps an explicit 4 MB test window at `0x8000_0000` (`-GRAM_BASE` in the Makefile). | `rtl/soc/soc_top.sv`, `rtl/cpu/pd_cpu.sv`, `rtl/cpu/cpu_top.sv` |
| 2 | RAM uncached alias (B02) | absent | - | `0x3000_0000`, 128 KB, same physical RAM, not cacheable. Folded onto the RAM window before the interconnect decode. | `rtl/aon/aon_subsys.sv` |
| 3 | Unmapped address response | DECERR | - | SLVERR | `rtl/bus/axil_demux.sv` |
| 4 | Debug range `0x2000_8000` | absent | - | Reserved in the map; the debug branch is not part of stage 1, so it returns SLVERR (boot test checks this). | doc/SOC_REGMAP.md |
| 5 | CPU core | PicoRV32 stand-in | in-house core | In-house core; PicoRV32 removed. | `rtl/cpu/pd_cpu.sv` |
| 6 | Quiesce handshake (B09, W03) | `idle_req`/`idle_ack`, WFI held while requested | no handshake | SPEC power handshake: `idle_ack` = pipeline drained and no outstanding bus transaction; the core does not leave WFI while the handshake is active. | `core_top.sv`, `cpu_top.sv` |
| 7 | `cache_clean` (W02) | stand-in tied to 1 | `caches_idle_o` (FSM idle) | `cache_clean` = no dirty D-cache line; "caches idle" never substitutes for it. | `dcache.sv` |
| 8 | Maintenance completion on write-back error (W35) | - | completion reported, dirty bit cleared on error; eviction errors cleared at the next maintenance start | Completion only after every write response arrived without error; error reported to software. Failed lines stay dirty (so `cache_clean` stays low); eviction errors are reported by the next operation; firmware checks `mcachectl[31]`. | `dcache.sv`, `fw/crt0.S` |
| 9 | PMU power-down condition | `cache_clean` only | - | Power down only while `idle_ack` and `cache_clean` are both asserted (plus bus idle); SVA `a_iso_on_bus_idle` extended. | `rtl/aon/pmu.sv` |
| 10 | Interrupt synchronization (W05) | inside the stand-in core | expects synchronous inputs | Synchronized exactly once, at the CPU boundary (`pd_cpu.u_async_sync`). | `pd_cpu.sv` |
| 11 | `mtime` (B10) | internal to the timer | `mtime_i[63:0]` input | Exported from PD_AON with a safe crossing: four-phase snapshot handshake (`cdc_snapshot_src/dst`), formally proven. | `rtl/common/cdc_snapshot_*.sv` |
| 12 | Reset / clock ownership (W06, W07) | reset released on the ungated root clock, ack to PMU, reset-clocking window | async reset core | SoC scheme kept: PD_AON owns `clk_cpu` (DVFS mux + ICG) and the CPU reset (async assert, release on `clk_cpu_root`, ack to the PMU). Documented in doc/CPU_SOC_INTERFACE.md. | - |
| 13 | WFI wake condition (W04) | wake on raw interrupt | wake on `mip & mie` | RISC-V privileged spec (`mip & mie`); firmware enables its wake sources in `mie`. SoC firmware ported. | `fw/pm_test.c`, `fw/boot_test.c` |
| 14 | Firmware compiler / ISA string (W28) | clang/lld, `-march=rv32im` | GCC, `rv32im_zicsr_zifencei` | GCC 13.2 / binutils 2.42, `-march=rv32im_zicsr_zifencei -mabi=ilp32`, no compressed instructions (the firmware build fails if one appears). | `fw/Makefile` |
| 15 | Resume validation | magic only | - | The boot ROM restores context only if its CRC matches: CRC-32 over the saved context (GPRs + mstatus/mie/mtvec/mscratch), plus magic and pointer range checks; otherwise cold boot. Interim ABI in `fw/crt0.S` (doc/BOOT_ABI.md does not exist yet). | `fw/crt0.S` |
| 16 | Register maps | doc/SOC_REGMAP.md | - | SOC_REGMAP.md normative; changed only where SPEC requires: memory map (debug range, alias, cacheable windows), SLVERR for unmapped, ERR_DIRTY meaning (idle_ack or cache_clean missing), mie wake-source note in the low-power entry sequence. | doc/SOC_REGMAP.md |
| 17 | Verification rules | coverage exemptions in the bench; aborted refusals counted as RUN->IDLE coverage | coverage holes printed with exit 0; mutation runner exit 0 with survivors | Holes fail unless waived with a reason; aborted transitions reported as ABORTED and never counted; required-test lists; negative tests for every checker. | `scripts/`, `dv/regress/`, `sim/tb_soc.sv` |
| 18 | Tool versions | Verilator 5.054 | Verilator 5.052 | One script, Verilator 5.054 (5.052 has a constrained-random bug that breaks the PMU unit test, see Bugs). | `scripts/setup_toolchain.sh` |

### Bugs found

Design (RTL):

1. **D-cache: maintenance reported success after a failed write-back (W35,
   CPU branch).** The dirty bit was cleared even when a write response was an
   error, and an eviction write-back error was erased by the next maintenance
   start, so a clean could report success with data missing from memory. Fixed
   (`dcache.sv`); covered by new directed bench phases 4a/4b and by mutants
   `dc_clean_on_error`, `dc_evict_err_lost`.
2. **mtime crossing torn capture (found by formal in this stage's own first
   version).** The first toggle-handshake version of the crossing could take a
   stale acknowledge from before a CPU-side reset as the answer to a new
   request and capture the snapshot in the cycle it changed. Found by the new
   SymbiYosys proof (`formal/cdc_snapshot.sby`); redesigned as a four-phase
   handshake with a post-reset settle window and an explicit minimum
   CPU-reset length (6 clk_aon edges), which the SoC bench asserts and its
   negative test provokes.
3. **D-cache `cache_clean` lagged a store by one cycle** in this stage's first
   implementation (registered from the dirty bits). Now low from the cycle a
   cacheable store is accepted; the cache bench checks the `cache_clean`
   contract on the AXI bus (no write-back in flight while clean, no write-back
   during a clean that started clean); mutant `dc_clean_during_evict`.

Verification / flow:

4. **CPU coverage script false pass** (`scripts/cov_report.py`): holes were
   printed and the script exited 0; missing coverage databases were ignored.
   Fixed; the existing hole `cp_wb_error` is now an explicit waiver with a
   reason (`dv/coverage_waivers.txt`).
5. **Mutation runner false pass** (`scripts/mutation.py`): exit 0 regardless
   of survivors, build failures or mutants whose edit no longer applies. Fixed.
6. **SoC bench counted a refused SLEEP as a completed RUN->IDLE transition**
   (power-down refused with a dirty D-cache). Now reported as ABORTED and never
   counted.
7. **SoC lint not clean on Verilator 5.052**: the SoC branch's `make lint`
   reported 5 SYNCASYNCNET warnings on the reset synchronizer chains (that
   branch was verified on 5.054). Waived for the synchronizer cell with a
   reason.
8. **Verilator 5.052 constrained-random bug** (tool): `randomize()` returned 0
   for a satisfiable class with `dist` constraints (1 call in 50 in an isolated
   reproducer), which made the PMU unit test die. 5.054 passes the same
   reproducer 2000/2000; 5.054 is pinned.
9. **X false positive in the Icarus run**: the write-back D-cache writes whole
   lines, including never-written words refilled from uninitialized RAM (X in a
   4-state simulator), so the bench's "no X reaches PD_AON" check fired on X
   that did not come from PD_CPU. The bench now loads the RAM model with random
   power-up content (seeded), as a real SRAM has; X injected by the PD_CPU
   corruption model is still detected (negative test `iso-icarus`).
10. **Firmware timing assumptions from the PicoRV32 era**: wake timers of 1000
    clk_aon cycles expired before WFI, because the D-cache clean in
    `pm_suspend` (four single-beat writes per dirty line through the CDC
    bridge) and, after a SLEEP resume at OP0, cold-cache refills take longer.
    Measured, then the firmware cleans before arming timers and uses longer wake
    delays; no check was removed. A slow bitwise CRC (~3200 instructions) was
    replaced by a nibble-table CRC.

### Results

All numbers come from one run of `make test` on this branch (Verilator 5.054,
GCC 13.2.0 / binutils 2.42, Spike `f90d5af`, Icarus 12.0, Yosys 0.33,
SymbiYosys yosys-0.33, Z3 5.3.3, sv2v v0.0.13; 4 CPU cores). Re-run a single
number with the command next to it; `make test` runs all of them.

| Flow | Result | Command |
|---|---|---|
| Toolchain check | all 11 pinned tools match | `make toolchain` |
| Lint (Verilator -Wall) | SoC with and without SVA, CPU subsystem with and without SVA: clean | `make lint` |
| Spike lockstep co-simulation | 200/200 random seeds + 2/2 directed programs pass (202/202 required); 1,001,666 instructions, 20,237 exceptions, 18,033 interrupts compared against Spike; idle handshake exercised in the random runs | `make cosim` |
| riscv-arch-test 3.9.1 | 63/63 applicable tests pass (I 39, M 8, Zifencei 1, privilege 15); 0 not applicable | `make archtest` |
| Cache unit benches | D-cache 8/8 seeds (64,000 responses, 869 maintenance ops, 1,094,007 post-maintenance memory checks, 0 mismatches), I-cache 8/8 (72,000 responses), AXI mux 8/8; 24/24 required | `make cachetest` |
| CPU coverage | ISA plan 127/127, cover properties 66/67 (hole `cp_wb_error` waived with reason), covergroup bins 73/73; code (reported, not gated): line 96.5 %, branch 99.7 %, expression 99.2 %, toggle 87.2 % | `make coverage` |
| SoC pm_test, Verilator (random OFF-state corruption) | PASS; PMU arcs 23/24 (IDLE_REQ->WAKE_REL waived with reason), all 6 completed power-state transitions, all 6 DVFS pairs, 1 refused SLEEP reported as ABORTED, 12 corruption events (2715 state elements, 80,270 bits of the in-house CPU domain) | `make sim` |
| SoC pm_test, Icarus (4-state X corruption) | PASS, same coverage, no X reached PD_AON | `make sim-x` |
| SoC boot test, Verilator | PASS: ROM boot, RAM execution, mtime/rdtime, timer interrupt, uncached alias, SLVERR, dirty-D-cache refusal (ABORTED), SLEEP/resume with dirty D-cache data, CRC-rejected resume -> cold boot | `make boot` |
| SoC boot test, Icarus | PASS | `make boot-x` |
| SoC bench negative tests | 5/5 detected: defeated isolation (Verilator, Icarus X), firmware FAIL, timeout, too-short CPU reset | `make sim-neg` |
| PMU unit test | PASS, 400 episodes, full functional coverage (24/24 arcs, 6/6 DVFS pairs, 9/9 mode x wake source, dirty refusal, WFI abort, wake during DVFS) | `make sim-pmu` |
| Formal | FORMAL_RESULT | `make formal` |
| Mutation | MUTATION_RESULT | `make mutation` |
| Checker self-tests | SELFTEST_RESULT | `make selftest` |
| `make test` | MAKETEST_RESULT | `make test` |

Measured power-state latency (SoC bench, pm_test, clk_aon 41 ns, CPU OP0/1/2 =
47/23/11 ns; `make sim`, file `build/sim/cov_pm_test_verilator.txt`):

| Transition | n | min | max | avg |
|---|---|---|---|---|
| IDLE entry (WFI retired -> clock gated) | 12 | 352 ns | 2671 ns | 1013 ns |
| IDLE wake (wake event -> RUN) | 12 | 246 ns | 410 ns | 301 ns |
| SLEEP entry (WFI retired -> power off) | 6 | 745 ns | 2227 ns | 1051 ns |
| SLEEP wake | 6 | 1107 ns | 1312 ns | 1155 ns |
| DEEP_SLEEP entry | 6 | 2222 ns | 3073 ns | 2406 ns |
| DEEP_SLEEP wake | 6 | 1312 ns | 1435 ns | 1339 ns |

Not run: UVM (doc/SPEC.md places it on commercial simulators; no UVM content
is in the merged branches), UPF-aware simulation or static checks (no
open-source tool; `upf/soc_top.upf` is unchecked), FPGA build (later stage).
The CI workflow `.github/workflows/ci.yml` was written but not executed here.

### Open items for later stages

1. Firmware, debug and UVM branches (F, D, U) are not merged. Their register
   maps, boot/resume ABI and test-completion ABI conflict with
   doc/SOC_REGMAP.md (B03-B08, B11-B20, W11-W34); they must be ported to the
   SoC register map, and doc/BOOT_ABI.md and doc/DEBUG_SPEC.md written.
   `fw/crt0.S` holds an interim resume ABI (context with CSRs, CRC-32, PMU
   SCRATCH0/1).
2. Debug blocks at `0x2000_8000` are not implemented (SLVERR today); cache
   statistics from the debug event counters (doc/SPEC.md) do not exist yet.
3. PMU wake is `meip | mtip | msip` regardless of `mie`. A pending interrupt
   that firmware did not enable in `mie` makes the PMU wake the core, the core
   stays in WFI and the PMU enters IDLE again, repeatedly (functionally
   correct, wastes power). A wake mask needs a doc/SOC_REGMAP.md change.
4. The WFI-abort arc (IDLE_REQ -> WAKE_REL) is not reachable deterministically
   at SoC level; it is waived there and covered by the PMU unit test and the
   formal cover run.
5. Performance: the CPU's AXI4-Lite master issues single-beat transfers, each
   crossing the CDC bridge; a cold-cache SLEEP entry at OP0 took about 5100
   clk_aon cycles. Bursts or a wider bridge would help.
6. The reset-clocking window (RST_CLK_CYCLES, W07) is not needed by the
   in-house core (asynchronous resets) but kept; the UVM environment (U)
   forbids it and must be reconciled when it is merged.
7. The Spike co-simulation runs `cpu_top` alone; no lockstep check runs on
   the SoC-level firmware tests.
8. `upf/soc_top.upf` has not been checked by a UPF-aware tool.
9. CI (`.github/workflows/ci.yml`) has not run yet; source builds of
   Verilator and Spike take a long time without a warm cache.
