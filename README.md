<!-- Merged README (integration stage 1). Sections below come from the SoC branch and the CPU branch; see doc/INTEGRATION_REPORT.md for the integrated state. -->
# Low-Power RISC-V SoC

RTL, power intent and verification for a two-power-domain RISC-V SoC with
clock gating, power gating, RAM retention and DVFS. The specification is in
`doc/SPEC.md`, and the register map is in `doc/SOC_REGMAP.md`.

The CPU is currently **PicoRV32** (RV32IM, vendored in `third_party/picorv32`).
It is a temporary stand-in for the in-house 5-stage core, and a wrapper
(`rtl/cpu/cpu_core_picorv32.sv`) gives it the interface the SoC expects.

## Directory layout

| Path | Contents |
|------|----------|
| `rtl/tech/` | Technology wrappers with generic models: ICG, clock OR, synchronizer, isolation, power switch, RAM with retention, ROM |
| `rtl/common/` | Reset synchronizer, async FIFO (Gray pointers), sync FIFO |
| `rtl/bus/` | AXI4-Lite CDC bridge, 1:N interconnect, AXI4-Lite to register adapter |
| `rtl/clk/` | Glitch-free 3-input DVFS clock multiplexer |
| `rtl/aon/` | PMU, UART, machine timer, wake timer, interrupt controller, memory front end, AON subsystem |
| `rtl/cpu/` | `pd_cpu` (the PD_CPU boundary) and the PicoRV32 stand-in wrapper |
| `rtl/soc/` | `soc_top`, CPU clock-gate and reset control |
| `rtl/include/sva_macros.svh` | Assertion macros: concurrent SVA (Verilator), immediate + `$past` (Yosys), empty (Icarus) |
| `upf/soc_top.upf` | IEEE 1801 power intent |
| `fw/` | Boot ROM / power-management integration test firmware (C + asm, clang/lld) |
| `sim/tb_soc.sv` | SoC testbench: firmware run, OFF-state corruption, X checks, transition coverage, latency |
| `sim/pmu/tb_pmu.sv` | PMU unit testbench: SV classes, constrained random, reference model, SVA, cover properties |
| `formal/` | SymbiYosys harnesses: PMU, DVFS mux, async FIFO |
| `scripts/` | Corruption-model generator, bin2hex, VCD dump helper |
| `lint/` | Verilator waivers (third-party core; reset-net use in `disable iff`) |

## Architecture

### Power domains and clocks

```
              clk_op_i[2:0] (OP0 slow .. OP2 fast)
                    |
          +---------v----------+      clk_cpu_root    +--------------+  clk_cpu
          | dvfs_clk_mux       |--------------------->| ICG (PMU)    |---------+
          +--------------------+                      +--------------+         |
 PD_AON (clk_aon)                                                              |
 +-----------------------------------------------------------------------+     |
 | PMU   wake timer   mtimer   intc   UART   ROM 16K   RAM 128K (ret)     |     |
 |   ^          AXI4-Lite interconnect (axil_demux)                         |     |
 |   |                     ^                                              |     |
 |   |        axil_cdc_bridge (5 async FIFOs)  <---- tech_iso (clamp 0) <-+-----+--+
 |   +-- iso_en, pwr_sw_en, cpu_rst, cg_en, idle_req, dvfs_sel, vsel      |     |  |
 +-----------------------------------------------------------------------+     |  |
                          tech_pwr_switch --> PD_CPU supply                     |  |
                                         +--------------------------------+    |  |
                                         | PD_CPU  u_pd_cpu (clk_cpu)      |<---+  |
                                         |   cpu_core_picorv32             |-------+
                                         +--------------------------------+
```

- **PD_AON** (always on, `clk_aon_i`): the PMU, bus, CDC bridge, isolation
  cells, clock/reset control, DVFS mux, timers, interrupt controller, UART,
  boot ROM and main RAM.
- **PD_CPU** (switchable, `clk_cpu`): everything below `u_pd_cpu`.
- `clk_aon_i` and the three `clk_op_i` are mutually asynchronous.

### Clock-domain crossings

| Crossing | Direction | Mechanism |
|----------|-----------|-----------|
| CPU AXI4-Lite master | clk_cpu -> clk_aon | `axil_cdc_bridge`: one Gray-pointer async FIFO per AXI channel |
| Bridge slave-side idle | clk_cpu -> clk_aon | registered level + `tech_sync` |
| core_sleep, idle_ack, cache_clean | clk_cpu -> clk_aon | `tech_sync` on flop outputs (levels, 4-phase protocol) |
| idle_req, meip/mtip/msip | clk_aon -> clk_cpu | `tech_sync` inside the core wrapper |
| Clock-gate enable / ack | clk_aon <-> clk_cpu_root | `tech_sync` both ways (`cpu_clk_rst_ctrl`) |
| CPU reset release / ack | clk_aon <-> clk_cpu_root | async-assert / sync-release `rst_sync`; release state synced back |
| DVFS select / status | clk_aon <-> clk_op[i] | per-branch synchronizers in `dvfs_clk_mux`; status synced in `soc_top` |
| ext_wake_i, uart_rx_i | async -> clk_aon | `tech_sync` |

The bridge is in PD_AON. Its slave-side flops run on the gated CPU clock and
are reset only by power-on reset, so FIFO pointers stay coherent across
PD_CPU power cycles. The PMU isolates the CPU only when the bridge reports
idle (`idle_m_o`).

### PMU sequencing (`rtl/aon/pmu.sv`)

Firmware selects `CTRL.MODE` and executes WFI. The PMU then performs:

- **IDLE**: idle_req/idle_ack handshake, then gate clk_cpu. If a DVFS target
  is pending, DVFS runs here: raise the voltage if going faster, switch the
  glitch-free mux, lower the voltage if going slower, then raise DVFS_DONE.
- **SLEEP**: IDLE entry, then wait for the bus to be idle, isolation on, CPU
  reset on, switch off.
- **DEEP_SLEEP**: SLEEP, then RAM retention.
- **Wake** (meip | mtip | msip): RAM retention off (from DEEP_SLEEP), switch
  on, wait for power-good, clock the core briefly in reset (PicoRV32 has a
  synchronous reset; `RST_CLK_CYCLES = 0` skips this), release reset,
  isolation off, ungate the clock, release idle_req.
- **Safety paths**:
  - If the core leaves WFI before it acknowledges idle_req, the PMU aborts
    the entry.
  - If the core reports a dirty D-cache, the PMU refuses the power-down
    (`STATUS.ERR_DIRTY`) and keeps the core in IDLE.

The boot ROM (`fw/crt0.S`) tells a resume from a cold boot by checking
`PMU.STATUS.RESUME` together with a magic value in `PMU.SCRATCH1`. On resume
it restores the callee-saved context that `pm_suspend()` saved to RAM, so
`pm_suspend()` returns 1. It clears all registers on entry.

### WFI on the PicoRV32 stand-in

PicoRV32 has no WFI, so the wrapper emulates it:

- The fetched WFI word is replaced by a NOP.
- The wait state starts at the next sequential instruction fetch. By then
  every older instruction has retired; PicoRV32 can prefetch the WFI before
  an earlier store executes.
- The core leaves WFI on an interrupt, but only after the PMU has withdrawn
  idle_req.
- `cache_clean_o` is tied to 1, because PicoRV32 has no cache.

### Technology wrappers

Technology cells are instantiated only through `rtl/tech/*`. The generic
models are synthesizable:

- The power switch model is a counter on clk_aon. For FPGA it reduces to
  "PMU holds the reset and gates the clock".
- The RAM model drives X on its read port while in retention.

Swap the module bodies for library cells (ASIC) or BUFGCE/BUFGMUX/BRAM
(FPGA).

## Verification

### Running

```bash
make test          # lint, firmware, all simulations, all formal jobs
make lint | fw | sim | sim-x | sim-neg | sim-pmu | formal
```

Required tools:

| Tool | Version |
|------|---------|
| Verilator | `sim-pmu` needs >= 5.028 for `randomize()` constraints (5.020 ignores them); other targets also work with 5.020 |
| Icarus Verilog | 12 |
| Yosys | 0.33 |
| SymbiYosys | matching Yosys |
| Z3 | 4.12 or newer (Ubuntu 24.04's 4.8.12 hangs in `yosys-smtbmc`; the Ubuntu Boolector cannot parse its SMT2) |
| clang + ld.lld | riscv32 target |
| Python | 3 |

The results below were produced with Verilator 5.054 (built from source),
Icarus 12.0, Yosys 0.33, SymbiYosys `yosys-0.33`, Z3 5.3.3 (PyPI
`z3-solver`) and clang/lld 18.

### Lint

`verilator --lint-only -Wall` is clean on all RTL, with and without SVA, on
Verilator 5.020 and 5.054. Waivers are in `lint/`.

### SoC simulation (`sim/tb_soc.sv`, `fw/pm_test.c`)

The firmware runs from the boot ROM and checks itself, printing PASS or FAIL
over the UART. It covers:

- IDLE woken by the wake timer, the machine timer, and an already-pending msip
- All six DVFS operating-point changes, checking the measured CPU/AON clock
  ratio
- SLEEP and DEEP_SLEEP woken by the wake timer and by the external wake pin,
  with RAM and stack checksums across the power cycle
- A 12-iteration stress loop mixing modes and DVFS points

The testbench checks:

- **OFF-state corruption model** (`scripts/gen_corrupt_model.py`, generated
  from the Yosys netlist of PD_CPU: 227 state elements / 2931 bits). When the
  PD_CPU supply drops, every state element is overwritten and every PD_CPU
  output is forced. At power-up the state is corrupted again.
  - `make sim` (Verilator) uses random values.
  - `make sim-x` (Icarus) uses X and checks that no unknown value reaches
    PD_AON.
- `make sim-neg` defeats the isolation and requires both simulators to flag it.
- SVA in all RTL blocks (Verilator), isolation and reset when the supply is
  off, and no RAM access during retention.
- Transition coverage:
  - PMU FSM arcs: 22 of 24 at SoC level. The two missing arcs, the WFI abort
    and the dirty-cache refusal, cannot be produced with PicoRV32 and are
    covered by the unit test and by formal.
  - All 6 architectural power-state transitions.
  - All 6 DVFS transitions.

### PMU unit test (`sim/pmu/tb_pmu.sv`)

A class-based testbench drives randomized low-power episodes:

- Mode, DVFS target, wake source and wake time
- WFI-abort and dirty-cache injection
- Response latencies of the clock gate, switch, reset, mux and bus

Reactive models stand in for the core and the environment. A reference model
checks STATUS, SLEEP_CNT, WAKE_CAUSE, CUR_OP, VSEL, the interrupt and RAM
retention after every episode. The test passes only with full functional
coverage:

- All 24 FSM arcs
- All 6 DVFS pairs
- Every mode × wake-source combination (9 bins)
- Dirty-cache refusal in SLEEP and in DEEP_SLEEP
- WFI abort
- Wake during DVFS

Two hand-made PMU mutations (voltage not raised before a speed-up, SLEEP_CNT
not counting DEEP_SLEEP) are each caught: the first by SVA, the second by the
reference model.

### Formal (`formal/*.sby`)

| Job | Engine | Result |
|-----|--------|--------|
| `pmu prove` | k-induction (smtbmc z3) | Unbounded proof of all 28 PMU assertions (plus 8 harness invariants on the environment): isolation whenever not powered, switch-off only isolated and in reset, isolation release only after power-good and reset release, clock gated around isolation changes, handshake before gating, RAM retention only with CPU off, DVFS select changes only gated, voltage never below the running clock's operating point, plus the per-state output contract. Environment assumptions are in `formal/pmu_formal.sv`. |
| `pmu cover` | smtbmc z3 | All 24 FSM arcs reachable (non-vacuity) |
| `dvfs_mux prove` | abc pdr, multiclock | Unbounded, with three arbitrary unrelated clocks. A gated branch clock only rises or falls with its source, at most one branch is active, and a branch starts only after all branches were low. |
| `dvfs_mux cover` | smtbmc z3 | Switch to OP0, to OP1, and back to OP2 |
| `async_fifo prove` | abc pdr, multiclock | Unbounded: data arrives in order and intact, no overflow or underflow, the writer-side empty flag is safe |
| `async_fifo cover` | smtbmc z3 | Full, and pointer wrap-around |

The `dvfs_mux` proof found a real race. The mux reported "switch done" before
the other branches' synchronizers had observed the new branch, so an
immediate second switch could overlap two clocks. The mux now reports a
branch only after every other branch has seen it (`active_o`).

### Measured power-state latency

These are simulation numbers at clk_aon = 41 ns, with the CPU at OP2/OP1/OP0
= 11/23/47 ns and a power-switch model of `PSW_ON_DLY = 8` and
`PSW_OFF_DLY = 4` clk_aon cycles:

| Transition | Latency |
|------------|---------|
| WFI retired -> clock gated (IDLE) | 377–533 ns (~9–13 clk_aon) |
| WFI retired -> power off (SLEEP / DEEP_SLEEP) | 747–932 ns (~18–23 clk_aon) |
| Wake event -> RUN, from IDLE | 246–410 ns |
| Wake event -> RUN, from SLEEP | 1.1–1.2 µs |
| Wake event -> RUN, from DEEP_SLEEP | 1.3–1.4 µs |

The latency is dominated by two-flop synchronizer round trips:

- core_sleep / idle_ack / cg_ack / rst_ack are each synchronized into clk_aon.
- idle_req and cg_en are synchronized into clk_cpu.

The CPU-to-AON bus crossing is not on this path. With a 32.768 kHz clk_aon,
the same ~20 cycles would take about 0.6 ms.

## Status against `doc/SPEC.md`

Implemented in this repository:

- SoC top
- AON peripherals (UART, machine timer, wake timer, interrupt controller,
  ROM, RAM with retention)
- PMU with RUN/IDLE/SLEEP/DEEP_SLEEP and DVFS (3 operating points, voltage
  sequencing)
- Glitch-free DVFS clock mux
- All clock-domain crossings
- Technology wrappers
- UPF
- SVA
- SymbiYosys proofs
- OFF-state corruption model
- Power-state transition coverage
- `make test`

Not implemented yet:

- The in-house RV32IM pipeline and its caches (PicoRV32 stands in; no D-cache
  flush yet)
- Spike lockstep co-simulation and riscv-arch-test
- Cache verification
- cocotb tests: none exist in this repository yet; new testbenches are
  SystemVerilog per project direction
- UVM
- The full firmware set (drivers, validation suite, UART monitor). `fw/` holds
  only the power-management integration test and the resume-capable boot
  code.
- FPGA build

Other notes:

- No UPF-aware tool is available here, so `upf/soc_top.upf` has not been
  checked by a tool.
- The corruption model runs in plain RTL simulation, without UPF.
- The firmware relies on PicoRV32's `rdcycle` and uses no M-mode CSRs or
  interrupt entry; wake-up works by polling after WFI.

---

# CPU subsystem (merged from the CPU branch)

Specification: [doc/SPEC.md](doc/SPEC.md).

Implemented so far: the PD_CPU subsystem, i.e. the RV32IM 5-stage core, 4 KB 2-way I-cache, 4 KB 2-way write-back D-cache and AXI4-Lite master mux, together with its verification. Details: [doc/CPU.md](doc/CPU.md) (micro-architecture) and [doc/VERIFICATION.md](doc/VERIFICATION.md) (flows, results, bugs found).

## Layout

```
rtl/pkg      riscv_pkg.sv               encodings, CSR addresses, pipeline types
rtl/core     core_top, core_fetch, core_decoder, core_regfile, core_alu,
             core_muldiv, core_csr
rtl/cache    icache.sv, dcache.sv
rtl/bus      axil_mux2.sv
rtl/cpu      cpu_top.sv                 PD_CPU top (core + caches + mux)
rtl/tech     tech_sram_sp.sv            SRAM wrapper (generic model)
dv/cosim     Verilator C++ testbench, Spike lockstep co-simulation,
             random instruction generator, ISA + micro-architectural coverage
dv/archtest  riscv-arch-test model header
dv/cache     SystemVerilog class-based constrained-random unit testbenches
             (I-cache, D-cache, AXI4-Lite mux)
dv/common    AXI4-Lite memory model, ELF loader (C++)
sw/tests     directed test programs; sw/common/link.ld
scripts      regression runners, coverage report, mutation analysis, tool setup
third_party  riscv-arch-test (submodule, tag 3.9.1)
```

## Tools

| Tool | Version used | Purpose |
|---|---|---|
| Verilator | 5.052 (≥ 5.036 needed for `--timing` classes and randomize) | simulation, lint, coverage |
| z3 | 4.8.12 | SMT solver used by Verilator for constrained `randomize()` |
| Spike | riscv-isa-sim f90d5af (1.1.1-dev), built as `libriscv` | reference model |
| GCC | riscv64-unknown-elf 13.2 | test programs |
| riscv-arch-test | 3.9.1 | compliance tests |

`scripts/setup_tools.sh` installs them on Ubuntu 24.04. Then:

```bash
git submodule update --init
```

```bash
export PATH=/opt/verilator/bin:$PATH
```

## Running

```bash
make test          # lint + cosim + archtest + cachetest + coverage
```

| Target | What it does |
|---|---|
| `make lint` | `verilator --lint-only -Wall` on all RTL |
| `make cosim` | directed tests plus `COSIM_SEEDS` (default 200) random programs, each in lockstep with Spike |
| `make archtest` | riscv-arch-test rv32i_m I/M/Zifencei/privilege, signatures compared against Spike |
| `make cachetest` | SV unit testbenches: I-cache, D-cache, AXI mux (`dv/cache`, `SEEDS`, `N`) |
| `make coverage` | merged functional + code coverage, written to `build/coverage/report.md` |
| `python3 scripts/mutation.py` | injects RTL bugs and checks that the flows detect them |

Variables: `SPIKE_PREFIX` (default `/opt/spike`), `VERILATOR`, `RV_PREFIX`, `COSIM_SEEDS`, `COSIM_LEN`, `JOBS`.

To reproduce a single random seed:

```bash
python3 dv/cosim/gen_rand.py --seed 42 -o t.S
```

```bash
riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -T sw/common/link.ld t.S -o t.elf
```

```bash
build/cosim/obj/Vcosim +elf=t.elf +seed=42 +memcmp=1 +irq_rate=20 +ready_pct=60 +max_lat=4 +trace=t.trace
```

## Status

| Block | Status |
|---|---|
| Core, caches, AXI4-Lite mux | implemented and verified, see [doc/VERIFICATION.md](doc/VERIFICATION.md) |
| AXI4-Lite interconnect, boot ROM, RAM, UART, timer, interrupt controller, PMU, clock/power infrastructure, UPF, firmware, FPGA | not started |
