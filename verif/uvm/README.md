# PMU subsystem UVM environment

SystemVerilog UVM (IEEE 1800.2) environment for the PD_AON Power Management
Unit described in `doc/SPEC.md`, written as reusable verification IP. It
verifies the PMU at subsystem level only: through its AXI4-Lite slave port and
its PD_CPU power control/status pins.

The PMU RTL is developed on another branch. Until it is merged, the environment
runs against a small stub in `stub/`; the agents, scoreboard and tests do not
depend on the stub's internals.

## Scope

Covered here:

- AXI4-Lite and power-pin agents, register model, scoreboard with a reference
  model of the power sequencing, functional coverage, tests, run scripts.

Not covered here (owned by the PMU block-level branch):

- cocotb block-level tests, formal proofs, the OFF-state corruption model and
  the power-sequencing SVA. No power-sequencing assertions or formal properties
  are written in this directory. `tb/pmu_sva_bind.sv` binds the other branch's
  SVA once it is merged (see [Binding the power-sequencing SVA](#binding-the-power-sequencing-sva)).
- Nothing under `rtl/` or any cocotb directory is touched.

## Layout

```
verif/uvm/
  stub/pmu_stub.sv                 stand-in PMU (synthesizable, Verilator -Wall clean)
  agents/axi_lite/                 AXI4-Lite master agent (reusable)
    axi_lite_if.sv                   interface, driver/monitor clocking blocks
    axi_lite_protocol_checker.sv     protocol SVA + cover properties (bound to the interface)
    axi_lite_pkg.sv  *.svh           cfg, item, driver, monitor, coverage, agent,
                                     RAL adapter, sequence library
  agents/pwr/                      power-domain agent (reusable)
    pwr_if.sv  pwr_defines.svh       interface, widths
    pwr_pkg.sv  *.svh                cfg, stimulus item, pin snapshot, reactive driver
                                     (power switch / CPU / wake-source model), monitor,
                                     pin coverage, agent, primitive sequences
  ral/pmu_ral_pkg.sv               register model (the only file with the register map)
  env/                             pmu_env_pkg: cfg, state tracker, scoreboard/reference
                                   model, coverage, virtual sequencer, env, vseq library
  tests/pmu_test_pkg.sv            tests
  tb/                              tb top, DUT wrapper, AXI checker bind, power-SVA bind hook
  scripts/                         pmu_uvm.f filelist, run_{xrun,questa,vcs,verilator}.sh,
                                   mk_bundle.py
  bundle/pmu_uvm_edaplayground.sv  generated single-file bundle
  Makefile                         run / regress / selfcheck / bundle
```

## Assumed PMU interface

`doc/SPEC.md` defines the power behaviour but no register map or pin list. The
stub and `ral/pmu_ral_pkg.sv` therefore use the following; adapt them to the
real PMU when it lands.

### Register map (AXI4-Lite, 32-bit, base address `+PMU_BASE`, default 0)

| Offset | Name | Access | Fields |
|---|---|---|---|
| 0x000 | ID | RO | 0x504D5501 |
| 0x004 | CTRL | RW | [0] PD_EN: WFI powers PD_CPU off (else IDLE); [1] RET_EN: power-off keeps RAM retention (DEEP_SLEEP) |
| 0x008 | STATUS | RO, volatile | [2:0] STATE (0 RUN, 1 IDLE, 2 SLEEP, 3 DEEP_SLEEP, 4 power-down, 5 power-up); [4] CLK_EN; [5] ISO_EN; [6] RET_EN; [7] PWR_EN; [8] PWR_GOOD; [9] CPU_RST_N; [13:12] DVFS_CUR; [16] DVFS_PEND |
| 0x00C | DVFS | RW | [1:0] OPP target; 3 is reserved and answered with SLVERR |
| 0x010 | WAKE_MASK | RW | [7:0] wake-source enables, reset 0xFF |
| 0x014 | WAKE_CAUSE | W1C | [7:0] enabled sources that caused wake-ups |
| 0x018 | SEQ_DELAY | RW | [7:0] clk_aon cycles between sequencing steps, reset 4 |
| 0x01C | PD_COUNT | RO, volatile | [15:0] completed power-downs |
| 0x100–0x10C | CPU_WIN.SCRATCH0–3 | RW | registers physically in PD_CPU: SLVERR unless PD_CPU is in RUN; lost on power-off |

Unmapped addresses return DECERR.

### Power pins (`pwr_if`)

PMU outputs: `clk_en` (clock gate), `iso_en`, `ret_en`, `pwr_en` (switch),
`dom_rst_n`, `dvfs_sel[1:0]`, `dom_out_iso` (isolated PD_CPU outputs).
PMU inputs driven by the power agent: `pwr_good`, `wfi`, `wake_irq[7:0]`,
`dom_out` (raw PD_CPU outputs). Widths: `PWR_IRQ_W` (8), `PWR_ISO_W` (16).

### Sequencing checked by the reference model

- Power-down: clock gate → isolation on → reset assert → [retention on,
  DEEP_SLEEP only] → switch off.
- Wake-up: switch on → power_good → [retention off] → reset release →
  isolation off → clock on.
- SPEC.md does not place the retention steps or the reset assert; the positions
  above are the stub's choice and live in two virtual functions
  (`pmu_scoreboard::pd_sequence` / `pu_sequence`) so a different documented
  order is a small override.
- IDLE: clock gate on WFI when CTRL.PD_EN=0; clock on when an enabled wake
  source is active.
- DVFS: `dvfs_sel` changes only in IDLE, only to the programmed legal OPP,
  never on the same edge as the clock enable. A change pending at IDLE entry
  must be applied before the clock restarts; a target written before SLEEP
  stays pending until the next IDLE.

## Components

### AXI4-Lite agent (`agents/axi_lite`)

- Driver: master, one transaction at a time. AW and W are driven by independent
  threads with their own random delays (AW first, W first, same cycle);
  BREADY/RREADY back-pressure; zero-delay items run back-to-back with no idle
  cycle. Random data is driven on payload while VALID is low.
- Monitor: pairs AW/W/B and AR/R, publishes each transaction with handshake
  timestamps (`t_req`, `t_exec`, `t_resp`), wait cycles and idle gap.
- Sequences: single read/write, back-to-back (writes, reads, alternating,
  write-then-read), random over address ranges with random delays and strobes,
  error-address sequence that counts OKAY/SLVERR/DECERR.
- Coverage: direction × response, strobes, request/response wait, back-to-back
  gap, AW/W order.
- Protocol checker (`axi_lite_protocol_checker.sv`, bound into every
  `axi_lite_if` by `tb/axi_lite_bind.sv`): VALID held and payload stable until
  READY on all five channels, no EXOKAY, VALIDs low in reset, no X on control or
  on valid payload, B only after both AW and W, R only after AR, bounded
  response latency; cover properties for channel orderings, back-pressure and
  each error response.

### Power agent (`agents/pwr`)

- Driver: a per-cycle model of everything around PD_CPU — power switch
  (`power_good` follows `pwr_en` with random on/off latency), CPU (raises WFI
  once running, drops it when its clock restarts or it is reset), wake sources
  (`PWR_WAKE` IRQs stay asserted until the CPU runs again, then clear after a
  random service time), and random garbage on raw PD_CPU outputs while the
  domain is not running (to exercise the clamps).
- Monitor: publishes a snapshot of every pin whenever any pin changes.
- Primitive sequences: WFI, wake, IRQ pulse (e.g. masked sources), domain
  output pattern, wait.

### Register model (`ral/pmu_ral_pkg.sv`)

Frontdoor through the AXI4-Lite agent (`axi_lite_reg_adapter`), explicit
prediction from the monitor (`uvm_reg_predictor`), `check_on_read` enabled on
the PD_AON registers. The PD_CPU registers are a sub-block (`CPU_WIN`) so the
scoreboard can recognise them; their data is checked by the scoreboard because
it has to account for power loss. Field-value covergroups are built inside the
register classes. DVFS is excluded from the bit-bash test (`NO_REG_BIT_BASH_TEST`)
because writing the reserved OPP is an error by design.

### Scoreboard (`env/pmu_scoreboard.svh`)

Reference model driven only by observed pins and bus transactions:

- Sequencing order for power-down and wake-up, one control pin per clock edge
  during sequencing, retention/reset/isolation/clock steps only with
  `power_good`, IDLE entry only with WFI, exit only with an enabled wake source,
  switch-on from SLEEP/DEEP_SLEEP only with an enabled wake source.
- DVFS rules above.
- Isolation clamps on every snapshot: `dom_out_iso == ISO_CLAMP` while
  isolated, `== dom_out` otherwise.
- Static invariants (clock enabled ⇒ not isolated, out of reset, powered;
  isolation off ⇒ out of reset and powered; retention ⇒ in reset; switch off ⇒
  in reset).
- Bus responses: DECERR for unmapped, SLVERR for reserved values and for any
  PD_CPU register access while PD_CPU is not in RUN, OKAY otherwise. An access
  whose request→response window overlaps a domain state change may get either
  OKAY or SLVERR (counted as "boundary" and covered).
- Read data: PD_AON registers via the RAL predictor; PD_CPU registers modelled
  in the scoreboard, including loss on domain reset, ordered against the reset
  with the bus timestamps; STATUS against the model state and the pins sampled
  during the read; WAKE_CAUSE ⊆ enabled sources seen at wake; PD_COUNT against
  counted power-downs.

Register-specific rules are virtual (`reg_resp`, `update_shadow`,
`check_volatile`, `pd_sequence`, `pu_sequence`) for factory overrides.

### Coverage (`env/pmu_coverage.svh` + RAL + agents)

- Power-state transition matrix: from {RESET, RUN, IDLE, SLEEP, DEEP_SLEEP} ×
  to {RUN, IDLE, SLEEP, DEEP_SLEEP}; impossible transitions are illegal bins.
  Crossed with low-power dwell time, wake-during-power-down and the OPP in force.
- DVFS: every OPP-to-OPP change (6 bins).
- Register fields: CTRL modes, DVFS OPP (incl. reserved writes), WAKE_MASK
  patterns, WAKE_CAUSE read/W1C, SEQ_DELAY ranges, STATUS state and OPP.
- Bus: register × direction, error reason × direction, reason × response,
  PD_CPU access × PD_CPU state, boundary accesses.
- Agent coverage: AXI transfer/timing, power pin edges.

### Virtual sequences (`env/pmu_vseq_lib.svh`)

`pmu_idle_vseq`, `pmu_sleep_vseq`, `pmu_deep_sleep_vseq`,
`pmu_wake_during_pd_vseq`, `pmu_dvfs_vseq` (all derived from
`pmu_pwr_trans_vseq`, which randomises wake mask/source, dwell, early wake,
masked-IRQ noise, SEQ_DELAY and a DVFS target), `pmu_pwr_matrix_vseq`
(deterministic: every state with three dwells, early wake, IDLE with RET_EN=1,
all six OPP changes, DVFS target pending across SLEEP), `pmu_pwr_rand_vseq`,
`pmu_bus_traffic_vseq` (background traffic safe during transitions),
`pmu_reg_rand_vseq`, `pmu_ral_builtin_vseq`, `pmu_err_vseq`.

### Tests (`tests/pmu_test_pkg.sv`)

| Test | Content |
|---|---|
| `pmu_smoke_test` | cold boot, ID, scratch write/read, one IDLE, one SLEEP, scratch lost |
| `pmu_ral_test` | `uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq` (`+RAL_SEQ=hw_reset\|bit_bash\|all`) |
| `pmu_rand_reg_test` | random RAL writes/reads/mirrors, raw writes with random strobes, back-to-back bursts |
| `pmu_rand_pwr_test` | random transitions and DVFS changes with concurrent bus traffic |
| `pmu_pwr_matrix_test` | full transition matrix and all OPP pairs |
| `pmu_err_test` | DECERR (unmapped), SLVERR (reserved OPP, PD_CPU accessed in IDLE/SLEEP/DEEP_SLEEP and across transitions) |
| `pmu_full_test` | all of the above in one run |

Every test prints `*** TEST PASSED ***` or `*** TEST FAILED ***` (UVM_ERROR or
UVM_FATAL count). `+PMU_ITERS=<n>` sets iteration counts, `+PMU_BASE=<hex>` the
register base.

## Running

All scripts take the same options:

```
-t TEST   UVM test (default pmu_smoke_test)
-s SEED   seed, or "random"
-b BUG    stub BUG_MODE (checker self-test), default 0
-n ITERS  +PMU_ITERS
-c        force recompilation
-g        GUI where supported
-- ...    extra plusargs, e.g. -- +UVM_VERBOSITY=UVM_HIGH
```

Seeds are passed to the simulator: `xrun -svseed`, `vsim -sv_seed`,
`simv +ntb_random_seed`, `+verilator+seed+`. Logs land in
`out/<sim>/bug<N>/<test>_s<seed>.log`.

```bash
scripts/run_xrun.sh -t pmu_rand_pwr_test -s 42
```

```bash
scripts/run_questa.sh -t pmu_err_test -s random
```

```bash
scripts/run_vcs.sh -t pmu_full_test -s 7
```

```bash
UVM_HOME=/path/to/uvm-verilator/src scripts/run_verilator.sh -t pmu_full_test -s 3
```

Make targets (`SIM=verilator|xrun|questa|vcs`):

```bash
make run SIM=xrun TEST=pmu_pwr_matrix_test SEED=5
```

```bash
make regress SIM=questa SEEDS="1 2 3 4"
```

```bash
make selfcheck SIM=vcs
```

```bash
make bundle
```

Simulator-specific settings: `XRUN_UVMHOME` (default `CDNS-IEEE`),
`UVM_HOME` for Questa (defaults to a kit under `$MTI_HOME/verilog_src`),
`VCS_UVM` (default `uvm-ieee-2020`). `EXTRA_F` adds a filelist, `DEFINES`
adds `+define+` options.

`make selfcheck` rebuilds the stub with each `BUG_MODE` (1: isolation before
clock gate, 2: OKAY instead of SLVERR for PD_CPU while off, 3: no isolation
clamp) and requires `pmu_full_test` to fail for every one of them.

### EDA Playground

`bundle/pmu_uvm_edaplayground.sv` (regenerate with `make bundle`) contains the
stub, agents, RAL, env, tests and tb in one file. Paste it into `testbench.sv`,
select UVM 1.2 or IEEE 1800.2 and Xcelium/Questa/VCS, top module `pmu_tb_top`,
run option `+UVM_TESTNAME=<test>`.

## Swapping in the real PMU

1. Write a `pmu_dut_wrap` module with the same ports as `tb/pmu_dut_wrap.sv`
   (`clk_aon`, `rst_aon_n`, `axi_lite_if axi`, `pwr_if pwr`) that instantiates
   the real PMU, and put it in the filelist instead of the stub wrapper and
   `stub/pmu_stub.sv` (or pass the RTL filelist with `EXTRA_F`).
2. Set the isolation clamp value (`ISO_CLAMP` in `tb/pmu_tb_top.sv`), the base
   address (`+PMU_BASE`) and the response codes in `pmu_env_cfg` if they differ.
3. Replace the register map in `ral/pmu_ral_pkg.sv`. Keep PD_CPU-resident
   registers in a sub-block so `in_pd_cpu()` keeps working.
4. If the documented sequencing order or register semantics differ, extend
   `pmu_scoreboard` (override `pd_sequence`, `pu_sequence`, `reg_resp`,
   `update_shadow`, `check_volatile`) and register it with a factory type
   override in a test.
5. If the PMU synchronises asynchronous inputs, increase the power-agent
   latencies in `pwr_cfg` as needed; the reference model is pin-based and does
   not assume fixed latencies.

## Binding the power-sequencing SVA

The block-level branch owns those assertions. After it is merged:

```bash
make run SIM=xrun TEST=pmu_full_test EXTRA_F=<their filelist> DEFINES="+define+PMU_POWER_SVA +define+PMU_POWER_SVA_MODULE=<module> +define+PMU_POWER_SVA_TARGET=<pmu module>"
```

`tb/pmu_sva_bind.sv` then binds `<module>` into every `<pmu module>` instance
with `.*` port connections; adjust the bind if their ports do not match the PMU
port names.

## Verilator status

Run in this repository's cloud environment with Verilator 5.054 (built from
source, `--binary --timing`) and the Accellera IEEE 1800.2-2020 (2020.3.1) UVM
kit with Verilator patches (chipsalliance/uvm-verilator, branch
`uvm-2020-3.1-vlt`), compiled with `UVM_NO_DPI`. Constrained randomisation uses
Verilator's SMT-solver backend (z3 4.8.12). No commercial simulator was
available, so the xrun/Questa/VCS scripts and the EDA Playground bundle have not
been executed; the bundle was lint-checked with Verilator.

Observed Verilator behaviour:

- The full environment compiles and runs: agents, RAL (frontdoor, predictor,
  `check_on_read`, `uvm_reg_hw_reset_seq`, `uvm_reg_bit_bash_seq`), bound SVA,
  covergroups with crosses and illegal bins, clocking blocks.
- Verilator 5.054 ignored the class constraint `pmu_reg_dvfs::c_legal` when
  the register's field-value covergroup was constructed (an isolated probe
  with `pmu_ral_pkg` produced the reserved value 3 in about a quarter of 300
  `randomize()` calls with coverage enabled and never without it). A minimal
  non-UVM reproducer did not show the problem, so the root cause is not
  isolated. `pmu_reg_rand_vseq` re-randomises the DVFS field when this happens;
  on a compliant simulator that path is never taken.
- `UVM_NO_DPI` disables UVM's regex-based component-name checks and HDL
  backdoor; the environment uses neither.

### Verilator results (stub PMU)

`make regress SIM=verilator SEEDS="11 22 33"`: 21/21 runs pass (7 tests × 3
seeds). `make selfcheck SIM=verilator`: all three injected stub bugs are
detected (BUG_MODE 1 by `SB_ORDER`/`SB_INV`, 2 by `SB_RESP`, 3 by `SB_ISO`).
The single-file bundle also builds and passes `pmu_pwr_matrix_test` under
Verilator.

`pmu_full_test` coverage (from the env's report):

| Seed | Transitions (matrix / dwell / early wake / state×OPP) | DVFS | Bus & errors | AXI transfer |
|---|---|---|---|---|
| 11 | 97.8% (100 / 88.9 / 100 / 91.7) | 100% | 100% | 93.3% |
| 22 | 100% | 100% | 100% | 93.3% |
| 33 | 100% | 100% | 100% | 93.3% |

The AXI transfer hole is request-channel wait states (`cp_req_wait` short/long):
the stub is always ready on AW/W/AR when the single-outstanding driver issues a
request, so those bins can only be hit by a slave that back-pressures requests.
Coverage numbers come from the covergroups' `get_inst_coverage()`; Verilator's
`coverage.dat` files are saved next to each log but no merged report is
produced.
