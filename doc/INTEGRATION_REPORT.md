# Integration report

Stage 1: branch `integration`, created from `main` (`4849878`); stage 2: branch
`stage2` (below). doc/SPEC.md is normative;
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
11. **Co-simulation did not check the idle handshake strongly enough** (found
    by the fixed mutation runner: mutant `wfi_no_hold`, a core that leaves WFI
    while acknowledged, survived 24 seeds). The wake race was injected in only
    ~1 in 2 handshakes on one random line, and "no activity while idle_ack"
    looked only at VALID signals. Now all interrupt lines rise during 3 of 4
    acknowledged handshakes and transactions still in flight count as
    activity; the mutant is killed.
12. **Equivalent mutants**: `dc_clean_during_evict` as first written removed
    one of two redundant terms and could not be killed; it now removes both and
    is killed. `ack_not_quiescent` is equivalent with the current caches (a
    drained core implies idle caches and mux) and is waived with that reason in
    `dv/mutation_waivers.txt`.

### Results

All numbers come from one run of `make test` on this branch (Verilator 5.054,
GCC 13.2.0 / binutils 2.42, Spike `f90d5af`, Icarus 12.0, Yosys 0.33,
SymbiYosys yosys-0.33, Z3 5.3.3, sv2v v0.0.13; 4 CPU cores). Re-run a single
number with the command next to it; `make test` runs all of them.

The first complete `make test` on this branch failed 14/16: `mutation` (3
mutants not killed, bugs 11-12) and `selftest` (a crash in the self-test
harness itself, which now records a crash as a failure). Both were fixed; the
table is from the following clean run.

| Flow | Result | Command |
|---|---|---|
| Toolchain check | all 11 pinned tools match | `make toolchain` |
| Lint (Verilator -Wall) | SoC with and without SVA, CPU subsystem with and without SVA: clean | `make lint` |
| Spike lockstep co-simulation | 200/200 random seeds + 2/2 directed programs pass (202/202 required); 1,011,421 instructions, 20,239 exceptions, 19,059 interrupts compared against Spike; 770 PMU idle handshakes driven by the bench (with wake races), no activity while acknowledged | `make cosim` |
| riscv-arch-test 3.9.1 | 63/63 applicable tests pass (I 39, M 8, Zifencei 1, privilege 15); 0 not applicable | `make archtest` |
| Cache unit benches | D-cache 8/8 seeds (64,000 responses, 869 maintenance ops, 1,094,007 post-maintenance memory checks, 0 mismatches), I-cache 8/8 (72,000 responses), AXI mux 8/8; 24/24 required | `make cachetest` |
| CPU coverage | ISA plan 127/127, cover properties 66/67 (hole `cp_wb_error` waived with reason), covergroup bins 73/73; code (reported, not gated): line 96.5 %, branch 99.7 %, expression 99.2 %, toggle 87.2 % | `make coverage` |
| SoC pm_test, Verilator (random OFF-state corruption) | PASS; PMU arcs 23/24 (IDLE_REQ->WAKE_REL waived with reason), all 6 completed power-state transitions, all 6 DVFS pairs, 1 refused SLEEP reported as ABORTED, 12 corruption events (2715 state elements, 80,270 bits of the in-house CPU domain) | `make sim` |
| SoC pm_test, Icarus (4-state X corruption) | PASS, same coverage, no X reached PD_AON | `make sim-x` |
| SoC boot test, Verilator | PASS (2 corruption events): ROM boot, RAM execution, mtime/rdtime, timer interrupt, uncached alias, SLVERR, dirty-D-cache refusal (ABORTED), SLEEP/resume with dirty D-cache data, CRC-rejected resume -> cold boot | `make boot` |
| SoC boot test, Icarus | PASS | `make boot-x` |
| SoC bench negative tests | 5/5 detected: defeated isolation (Verilator, Icarus X), firmware FAIL, timeout, too-short CPU reset | `make sim-neg` |
| PMU unit test | PASS, 400 episodes, full functional coverage (24/24 arcs, 6/6 DVFS pairs, 9/9 mode x wake source, dirty refusal, WFI abort, wake during DVFS) | `make sim-pmu` |
| Formal (SymbiYosys) | 8/8 jobs: `pmu` prove (k-induction, unbounded) + cover (24/24 FSM arcs reached); `dvfs_mux` prove (PDR, unbounded, multiclock) + cover (3/3); `async_fifo` prove + cover (3/3); `cdc_snapshot` (new, mtime crossing) prove (PDR, unbounded) + cover (2/2) | `make formal` |
| Mutation | 21/22 mutants killed (by co-simulation and/or unit benches, 24 seeds each), 1 waived with reason (`ack_not_quiescent`, equivalent), 0 surviving, 0 build failures; 22/22 required | `make mutation` |
| Checker self-tests | 30/30: `check_results` (missing, unknown, FAIL not overwritten, SKIPPED, ABORTED, N/A rules, unreadable), `check_soc_cov` (hole, waiver rules, missing bin, aborted is not coverage, empty), `cov_report` (no databases, unwaived hole, waiver rules), `mutation.py` (survivor, build failure, not applied, waiver rules), `run_cosim` / `run_archtest` / `run_cachetest` parsers, PMU unit bench and PMU formal proof on a PMU mutant | `make selftest` |
| `make test` | 16/16 required steps PASS, exit 0, 1441 s from an empty `build/` | `make test` |

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

## Stage 2: firmware on the integrated SoC

Branch `stage2`, created from `main` (`9b1ad46`, stage 1 merged). One commit
per step (`a4f4b8e` .. see `git log 9b1ad46..stage2`). doc/SPEC.md stays
normative and unchanged; doc/SOC_REGMAP.md changed only for the PMU wake mask
(below); doc/BOOT_ABI.md is new.

### What was merged

| Branch | Head merged | Taken |
|---|---|---|
| `claude/zealous-planck-kdx8mw` (firmware, F) | `eca08ef` | boot ROM, drivers, power management, validation suite, UART monitor, Spike platform port, lpsoc platform port, tests (`fw/tests`, monitor session specs), tools (`mkimage.py`, `monitor_check.py`), `doc/firmware.md` |

Merge commit `a4f4b8e` (merged with `--no-commit`, the PicoRV32 platform
removed before the commit). The debug (`claude/wonderful-fermat-ll2di5`) and
UVM (`claude/affectionate-sagan-dzeoqn`) branches were not merged.

### What was deleted

From the firmware branch (doc/SPEC.md: the PicoRV32 platform is not part of
the design and may not be used in firmware platform code or as a test target):

- `platform/picorv32/` (SoC RTL `pico_soc`, `pico_pd_cpu`, `pico_cache`,
  `aon_pmu`, `aon_uart`, `aon_intc`, `aon_timer`, `bus_cdc`; testbench
  `tb_top.sv`; lint configuration; Makefile)
- `third_party/picorv32/` (core and patch), the RTL it added in `rtl/tech/`
  (`tc_clk_gate`, `tc_clk_mux_gf`, `tc_iso`, `tc_pwr_switch`, `tc_rst_sync`,
  `tc_sram`, `tc_sync`, `tc_vreg`; the SoC uses the stage-1 `tech_*` wrappers)
- `fw/arch/picorv32/`, the PicoRV32 IRQ stub in the boot ROM, the soft-mtvec
  handoff word, `doc/picorv32_platform.md`
- the memory-mapped cache driver and every operation `mcachectl` does not
  have (B07, W20), the testbench control device use (`0x4F00_0000`), the PMU
  software reset, reset-cause, event, counter and ID registers (none exists in
  doc/SOC_REGMAP.md), the timer prescaler test
- `tools/run_tests.py` (PicoRV32 runner and the false-passing result parser,
  replaced by the stage-1 checker)

From main: `fw/crt0.S`, `fw/link.ld` (ROM-resident programs), `scripts/bin2hex.py`
(replaced by `tools/mkimage.py`). `git grep -i pico` finds only doc/SPEC.md's
rule and the audit / this report.

### One firmware tree

`fw/` builds for `PLATFORM=lpsoc` (the SoC) and `PLATFORM=spike`
(doc/firmware.md). One copy of each driver, one boot ROM startup
(`fw/bootrom/start.S`) and one application startup (`fw/app/crt0.S`) shared by
all four applications: `suite` (validation suite + monitor), and main's
stage-1 programs `pm_test`, `boot_test`, `neg_fail`, now ported to the
drivers and the pm layer and booted from RAM by the boot ROM instead of being
ROM-resident. The testbench acts as the host: it preloads the application
image into RAM (`+ram=`) and a boot argument into the RAM host mailbox
(`+bootarg=`), and drives / records the UART (`+uart_in=`, `+uart_log=`).

### Conflicts and how doc/SPEC.md / doc/SOC_REGMAP.md decided them

Git conflicts: add/add on `.gitignore`, `Makefile`, `README.md`,
`fw/Makefile`, `fw/include/soc.h`; main's versions kept in the merge commit,
then the firmware tree was rebuilt (step 2) and `soc.h` rewritten from
doc/SOC_REGMAP.md (step 3). Interface conflicts:

| # | Conflict | main (stage 1) | Firmware branch | Decision | Where |
|---|---|---|---|---|---|
| 1 | Address map (B01) | SPEC map | RAM `0x2000_0000`, peripherals `0x4000_xxxx`, CLINT `0x4001_0000` | doc/SPEC.md address map | `fw/include/soc.h`, linker scripts |
| 2 | Uncached alias (B02) | `0x3000_0000` (RAM + `0x2000_0000`) | RAM + `0x1000_0000` | doc/SPEC.md: `0x3000_0000`; `UNCACHED()` = + `0x2000_0000` | `drivers.h`, tests 30-36 |
| 3 | PMU registers (B03, W11-W17) | SOC_REGMAP PMU | 16 different registers (WAKE_EN, RST_CAUSE, EVENT, SWRST, counters, ID) | doc/SOC_REGMAP.md. W11: DVFS completion is `STATUS.DVFS_DONE` through intc source 2; a request for the current OP completes at once in the driver (the PMU runs no sequence). W12: CTRL keeps LP_EN set. W13: SLEEP_CNT replaces the per-state counters. W15: the mode is sticky, `pm_suspend` writes IDLE afterwards. W16: a pending wake makes the entry return ABORTED (the PMU never starts); no wake source in `mie` is refused by the driver. W17: a SLEEP without the clean is refused by the PMU (ERR_DIRTY); test 46 now expects that refusal instead of a power cycle | `drivers/pmu.c`, `pm/pm.c`, tests 41-48, 50-52 |
| 4 | UART (B04) | TXDATA/RXDATA/STATUS/CTRL | DATA/STATUS/IE/DIV | doc/SOC_REGMAP.md | `drivers/uart.c`, test 70 |
| 5 | Machine timer, wake timer (B05) | separate timer and wake timer | CLINT layout, prescaler, no wake timer | doc/SOC_REGMAP.md; Spike keeps its CLINT offsets through the platform header (same driver); prescaler test removed (no prescaler); new wake-timer driver and tests 47, 75 | `drivers/timer.c`, `drivers/wtimer.c` |
| 6 | Interrupt controller (B06, W14) | PENDING/ENABLE/ACTIVE, sources 0 UART 1 wake timer 2 PMU 3 ext | software pending/clear, CLAIM, RAW; PMU at source 1 | doc/SOC_REGMAP.md; claim = lowest ACTIVE bit in the driver; tests raise real sources (UART TX idle, wake timer) | `drivers/intc.c`, tests 23, 24, 72 |
| 7 | Bus errors / access rules (W18, W19) | SLVERR; full-word registers | no error response, any strobe writes | doc/SPEC.md (unmapped: SLVERR) and doc/SOC_REGMAP.md (partial / RO writes: SLVERR, value kept); new test 76, monitor reports `ERR fault` | `t_drv.c`, `monitor.c` |
| 8 | Cache maintenance (B07, W20) | CSR `mcachectl` | MMIO controller `0x5000_0000`, line ops, dirty-discard, disable, statistics | doc/SPEC.md: CSR only. Clean / flush / I-invalidate; the error bit is checked after every clean (`warn_unused_result` + `-Werror`); unsupported operations and their tests removed, LRU / clean-keeps-valid checked functionally through the alias | `drivers/cache.c`, `pm_asm.S`, tests 30-36 |
| 9 | Boot / resume ABI (B08) | `fw/crt0.S`: SCRATCH0 pointer, SCRATCH1 magic, 20-word context, CRC | RST_CAUSE, context magic + CRC at RAM+0x40, image header | doc/BOOT_ABI.md (new): SPEC requires the CRC; SOC_REGMAP defines SCRATCH0/1 and has no reset-cause register. Detection: STATUS.RESUME + SCRATCH1 magic + SCRATCH0 = CTX_ADDR + context magic + CRC. Context layout and image header from the firmware branch, rebased; the "Reconciliation" table in doc/BOOT_ABI.md lists every item | `fw/bootrom`, `pm/pm.c`, `handoff.h` |
| 10 | Test completion (W29, W34) | UART `PASS` / `FAIL` line | testbench device at `0x4F00_0000` (exit, boot argument) | No such device in the doc/SPEC.md map: UART `PASS` / `FAIL 0x<code>` line, boot argument in a RAM host mailbox (doc/BOOT_ABI.md) | `platform/lpsoc`, `sim/tb_soc.sv` |
| 11 | OP numbering (W10) | OP0 slowest, OP2 reset | OP0 fastest | doc/SOC_REGMAP.md; baseline after every test is OP2 | tests 50-52, 60, 61 |
| 12 | Result checking (W29-W31) | stage-1 `check_results.py`, required lists | own parser, SKIPPED steps can pass | stage-1 checker (doc/SPEC.md verification rules) | step 7 |

### Hardware change: PMU wake mask (stage-1 open item 3)

doc/SOC_REGMAP.md first: PMU `WAKE_MASK` (0x24, RW, reset 0x7) and
`IDLE_CNT` (0x28, RO). Wake event = (meip, mtip, msip) & WAKE_MASK; the
firmware writes the sources it enabled in `mie` before every WFI
(`pm_wfi`, `pm_suspend`). Then `rtl/aon/pmu.sv` (register, masked wake,
counter), SVA `a_wake_masked`, `a_masked_holds`, `a_idle_cnt`,
`a_idle_cnt_hold`, covers `c_idle_masked_pending`, `c_off_masked_pending`;
formal (the PMU proof covers them, cover run 26/26); the PMU unit test (mask =
the core model's `mie`, a masked-out interrupt pending for 20-60 cycles must
not wake, IDLE_CNT in the reference model, three new coverage bins); the
firmware driver; self-test mutants (a PMU that ignores the mask fails the unit
test and the proof).

Repeated wake/sleep cycle, before and after (suite test 48 alone on the SoC,
`build/sim/vl/Vtb_soc +rom=build/fw/lpsoc/rom.hex +ram=build/fw/lpsoc/suite.hex +bootarg=80000030`):
MTIP pending but only MEIE enabled, wake by the wake timer.

| | PMU RUN -> IDLE_REQ during the one WFI | CPU clock cycles during the wait |
|---|---|---|
| before (stage-1 PMU) | 203 (arc counts in the coverage file) | 9158 of 12695 (72 %) over 3406 ticks |
| after | 1 (IDLE_CNT + 1, checked by the test) | 2860 of 12583 over 3376 ticks (test later lengthened to 8000 ticks) |

### Bugs found

Firmware / flow:

1. **Result parser false passes** (firmware branch `tools/run_tests.py`):
   `suite_verdict()` returned PASS for a log with an unknown test ID while a
   required test was missing, and for a log where `[TEST 1] FAIL` was followed
   by `[TEST 1] PASS` (results kept in a dict, last line wins). Reproduced
   before the fix. Replaced by `tools/fw_results.py` (conversion only) +
   `scripts/check_results.py`; negative tests `selftest/fw_results/*`.
2. **Image builder accepted an unaligned entry point** (`tools/mkimage.py`;
   entry `0x1000_1022` produced an image, exit 0). Now every doc/BOOT_ABI.md
   header rule is checked; negative tests `selftest/mkimage/*`; the boot ROM
   rejects such an image too (`fw-neg/rom-unaligned-entry`).
3. **Aborted transitions accepted as success**: `pm_idle()` returned
   `PM_WOKE` whether or not the PMU gated the clock; IDLE steps of the stress,
   coverage and monitor `sleep idle` commands, and main's pm_test (whose
   `pm_suspend` returned 0 both for a completed IDLE and for "not powered
   down") counted a WFI that fell through as an IDLE transition. The monitor's
   `sleep` command returned success for `PM_ABORTED`. Now `pm_idle()` checks
   `IDLE_CNT`, `pm_suspend` returns `PM_ABORTED` / `PM_EWB` distinctly, and
   every caller requires the completed result. Negative test
   `fw-neg/soc-idle-abort` (suite test 97 must FAIL; it passed before).
4. **Cold-I-cache timing assumptions from the PicoRV32 platform** (found
   running the suite on the SoC): test 25's 400-tick deadline expired before
   the WFI (742 ticks from the deadline computation to WFI with a cold
   I-cache; traced in the bench, mtime 1037938 > mtimecmp 1037596 at WFI);
   tests 51 and 71 sampled mtime and mcycle with a possible line refill in
   between (ratio 0.889 vs 0.872 at OP0, 2.81 vs 3.73 at OP2). Deadline 4000
   ticks; warm-up pass and the actually elapsed ticks. No tolerance changed.
5. **Boot ROM CRC table read uncached**: the table was in ROM, which the
   D-cache does not cache (doc/SPEC.md map), so each byte of a CRC was one
   uncached read through the CDC bridge; pm_test timed out. The table is now
   copied to RAM with `.data`.
6. **Suite summary line "FAILED: ..."** started with `FAIL` and ended the SoC
   bench run before the suite's own result lines; now "failed tests:".
7. **SoC bench UART input**: a prompt printed while a line was being sent
   released the next line early; Icarus rejected the input loop syntax.
8. **Bench negative test budget**: `iso-icarus` ended (6 ms) before the first
   power-off once pm_test boots through the ROM; 20 ms.

Hardware: the PMU wake behaviour above (stage-1 open item 3). No other RTL bug
was found by the firmware; the in-house CPU passed every CSR, exception
(including precise access faults for SLVERR) and interrupt test.

Tool / CI:

9. **CI: Z3 not on PATH.** `sudo python3 -m pip install --prefix /usr/local`
   with Ubuntu's Python 3.12 / pip 24.0 uses Debian's `posix_local` install
   scheme, so the `z3` script went to `/usr/local/local/bin`. Verified twice:
   the CI log (Ubuntu python3 3.12.3, "Successfully installed
   z3-solver-5.3.3.0", then Verilator's configure "checking for z3... no" and
   `--check` "z3 absent"), and here with `/usr/bin/python3.12` (preferred
   prefix scheme `posix_local`; the same command put `z3` in
   `/usr/local/local/bin`). Consequence beyond the check: CI's Verilator was
   built without an SMT solver for `randomize()`. Fix: Z3 in its own venv
   (`/opt/z3-5.3.3`), its binary linked into `/usr/local/bin`; the setup fails
   if the `z3` on PATH is not 5.3.3; `--check` also requires Verilator's
   compiled-in solver `z3 --in`, and the install rebuilds a cached Verilator
   without it. Re-run of the whole setup with Ubuntu's python3.12 as
   `python3`: `/usr/local/bin/z3 -> /opt/z3-5.3.3/bin/z3`, Z3 5.3.3.
10. **Verilator constraint solving** (tool limitation, worked around in the
    bench): Verilator 5.054 ignored the constraint `wake_mask[wake_src] == 1`
    (variable bit select); the PMU bench's post-randomize check caught it. The
    constraint is written with constant bit selects and the check stays.

### Results

All numbers come from one run of `make test` on branch `stage2` from an empty
`build/` (same tool versions as stage 1, plus the checks added in step 10;
4 CPU cores). Re-run a single number with the command next to it; `make test`
runs all of them.

| Flow | Result | Command |
|---|---|---|
| Toolchain check | all pinned tools match, including `verilator-solver z3 --in` (new) and `z3 5.3.3 (/usr/local/bin/z3)` | `make toolchain` |
| Lint (Verilator -Wall) | SoC with and without SVA, CPU subsystem with and without SVA: clean (PMU with the wake mask) | `make lint` |
| Firmware build | `lpsoc`: boot ROM 11,764 of 16,384 bytes; images suite 62,928 B, pm_test 11,104 B, boot_test 11,280 B, neg_fail 5,264 B; `spike`: suite.elf; no compressed instruction | `make fw` |
| Validation suite on the SoC (Verilator, in-house CPU) | 45/45 tests PASS, 0 skipped (CSR tests 2, 3 and access-fault test 14 included); 48/48 required results (tests, suite result, exit line, bench verdict); power-state coverage: 23/24 PMU arcs (IDLE_REQ->WAKE_REL waived as in stage 1), all 6 completed power-state transitions (RUN->IDLE 43, ->SLEEP 12, ->DEEP_SLEEP 17), all 6 DVFS pairs, 1 refused SLEEP reported as ABORTED, 29 OFF-state corruption events; 44 s | `make fw-suite` |
| Validation suite on Spike | `--priv=M` and `--priv=MSU`: 17 PASS + 27 N/A each, 20/20 required results each (HTIF exit 0) | `make fw-spike` |
| UART monitor sessions on the SoC | application monitor: 37 commands PASS (peek/poke/regs, bus-error responses, run tests, SLEEP / DEEP_SLEEP by timer and by UART RX, IDLE, OP changes, resume-rejected cold boot); boot ROM monitor (no image): 19 commands PASS (hand-poked program run with `go`) | `make fw-monitor` |
| Firmware negative tests | 5/5 detected: failing test 99 (SoC), aborted IDLE test 97 (SoC), Spike selftest build, ROM rejects an image with an unaligned entry point, ROM rejects an image with a bad CRC | `make fw-neg` |
| SoC pm_test (Verilator / Icarus 4-state) | PASS / PASS; 23/24 arcs (1 waived), 1 refused SLEEP ABORTED, 12 corruption events, no X reached PD_AON | `make sim`, `make sim-x` |
| SoC boot_test (Verilator / Icarus) | PASS / PASS (cold boot through the ROM image check, resume with dirty data, CRC-rejected resume -> cold boot, 2 corruption events) | `make boot`, `make boot-x` |
| SoC bench negative tests | 5/5 detected | `make sim-neg` |
| PMU unit test | PASS, 400 episodes, 0 holes: 24/24 arcs, 6/6 DVFS pairs, 9/9 mode x wake source, dirty refusal, WFI abort, wake during DVFS, masked pending interrupt held 45 / 45 / 92 (IDLE / SLEEP / DEEP) | `make sim-pmu` |
| Formal (SymbiYosys) | 8/8 jobs: `pmu` prove (k-induction, with the wake-mask and IDLE_CNT assertions) and cover (26/26: 24 arcs + 2 masked-pending covers); `dvfs_mux`, `async_fifo`, `cdc_snapshot` prove + cover as in stage 1 | `make formal` |
| CPU co-simulation, arch tests, cache benches, coverage, mutation | unchanged from stage 1: cosim 202/202 (1,011,421 instructions), archtest 63/63, cachetest 24/24, coverage gates met (1 waived hole), mutation 21/22 killed + 1 waived | `make cosim`, `make archtest`, `make cachetest`, `make coverage`, `make mutation` |
| Checker self-tests | 54/54 (stage 1: 30): new `fw_results/*` (11), `mkimage/*` (8), `monitor_check/*` (3), `tb_pmu/wake-mask-mutant`, `formal_pmu/wake-mask-mutant` | `make selftest` |
| `make test` | 20/20 required steps PASS (stage 1: 16 + `fw/suite-soc`, `fw/suite-spike`, `fw/monitor`, `fw/negative`), exit 0, 2093 s from an empty `build/` | `make test` |

Measured power-state latency in the validation suite on the SoC (file
`build/fw-suite/cov_suite.txt`, `make fw-suite`; ns, clk_aon 41 ns, CPU
OP0/1/2 = 47/23/11 ns):

| Transition | n | min | max | avg |
|---|---|---|---|---|
| IDLE entry (WFI retired -> clock gated) | 43 | 362 | 610 | 460 |
| IDLE wake (wake event -> RUN) | 43 | 246 | 451 | 304 |
| SLEEP entry (WFI retired -> power off) | 12 | 1873 | 2568 | 2020 |
| SLEEP wake | 12 | 1107 | 1312 | 1134 |
| DEEP_SLEEP entry | 17 | 1873 | 2618 | 2166 |
| DEEP_SLEEP wake | 17 | 1312 | 1517 | 1375 |

Single runs: the whole suite
`build/sim/vl/Vtb_soc +rom=build/fw/lpsoc/rom.hex +ram=build/fw/lpsoc/suite.hex +bootarg=8000ffff +timeout=2000000000 +cov=<file>`,
one test `+bootarg=800000<id in hex>`.

CI: see "CI" below.

Not run: UVM and UPF-aware checks (as in stage 1). In `make test` the
45-test suite runs on Verilator only; pm_test and boot_test also run on Icarus
(4-state). The full suite on Icarus was not completed (open item 5).

### CI

The workflow (`.github/workflows/ci.yml`) runs on pull requests and on pushes
to `main` only (previously also on the `integration` branch). It runs
`sudo scripts/setup_toolchain.sh`, then `scripts/setup_toolchain.sh --check`
on the job PATH (printing which `z3` it finds), then `make test`.

First fully green run: run 8, `make test` workflow, on the stage-2 pull
request (commit `2a491f4`),
https://github.com/MohsenMohamad/Low-Power-RISC-V-SoC/actions/runs/42113999232:

- Toolchain (tool cache miss: Verilator and Spike built from source): 14.5 min.
  Verilator's configure: `checking for z3... yes`; `--check`:
  `verilator-solver z3 --in ok`, `z3 5.3.3 (/usr/local/bin/z3) ok`,
  `TOOLCHAIN: all pinned versions present`.
- Toolchain check on the job PATH: `z3: /usr/local/bin/z3 -> /opt/z3-5.3.3/bin/z3`,
  `Z3 version 5.3.3 - 64 bit`.
- `make test`: 20/20 required steps PASS, `== make test: PASS`, 2357 s
  (ubuntu-24.04 runner; same steps and results as the local run above).

The run before the fix (run 6, `integration` branch, commit `1e32c35`) failed
in the Toolchain step with `z3 absent ... need 5.3.3 first on PATH`.

### Open items for later stages

1. Debug (D) and UVM (U) branches are not merged; doc/DEBUG_SPEC.md and the
   debug blocks at `0x2000_8000` do not exist (SLVERR). Cache statistics come
   from the debug event counters (doc/SPEC.md); the firmware branch's
   statistics-based cache checks were removed and are replaced by functional
   checks until those counters exist.
2. The SoC has no CPU-domain software reset (the firmware branch's PMU had
   one); reboot tests use a rejected resume instead. Adding one is a
   doc/SOC_REGMAP.md change.
3. WAKE_MASK must include every source enabled in `mie` before WFI
   (firmware contract, done by `pm_wfi` / `pm_suspend`); the hardware cannot
   see `mie` (PD_CPU) and does not check it, so a mask without the enabled
   source keeps the CPU gated until another masked-in source fires.
4. The D-cache write-back error path of the firmware (`PM_EWB`, ROM refusing
   to start an image) cannot be provoked on the SoC (RAM never errors while
   the CPU runs); it is covered by the D-cache unit bench only.
5. Full suite on Icarus not completed (stopped after 35 min without a result; not
   required for this stage). In
   `make test` the suite runs on Verilator only (44 s for 197 ms of simulated
   time). Command (after `make fw build/sim/iv/tb_soc.vvp`):
   `vvp -n build/sim/iv/tb_soc.vvp +rom=build/fw/lpsoc/rom.hex +ram=build/fw/lpsoc/suite.hex +bootarg=8000ffff +timeout=2000000000 +cov=build/fw-suite-icarus/cov_suite.txt`
6. Boot time: the ROM checks the CRC of the whole image before starting it,
   through single-beat AXI refills; for the 62 KB suite image this takes more
   than 8 ms of simulated time (the bad-CRC negative test did not reach the
   ROM's verdict within an 8 ms bench timeout and now uses 60 ms).
7. Stage-1 items still open: IDLE_REQ -> WAKE_REL not deterministically
   reachable at SoC level (waived, covered by unit test and formal); bus
   performance (single-beat AXI4-Lite through the CDC bridge); reset-clocking
   window vs UVM; no Spike lockstep on SoC-level firmware runs;
   `upf/soc_top.upf` not checked by a UPF-aware tool.
8. Stage-1 items closed here: item 1 for the firmware branch (merged and
   ported; doc/BOOT_ABI.md written), item 3 (wake mask), item 9 (CI fixed and
   run).
