# Low-Power RISC-V SoC

RTL, power intent, firmware and verification for a two-power-domain RISC-V SoC
with clock gating, power gating, RAM retention and DVFS.

| Document | Content |
|---|---|
| [doc/SPEC.md](doc/SPEC.md) | Specification (normative) |
| [doc/SOC_REGMAP.md](doc/SOC_REGMAP.md) | Address map and register maps (normative) |
| [doc/CPU_SOC_INTERFACE.md](doc/CPU_SOC_INTERFACE.md) | PD_CPU <-> PD_AON boundary: ports, clock domains, handshakes |
| [doc/CPU.md](doc/CPU.md) | In-house RV32IM core, caches, AXI mux |
| [doc/DEBUG_SPEC.md](doc/DEBUG_SPEC.md) | Debug blocks (trace buffer, event counters, error log, watchdog), debug firmware, bench (normative for the debug blocks) |
| [doc/TEST_PLAN.md](doc/TEST_PLAN.md) | Every doc/SPEC.md feature mapped to its tests and status |
| [doc/BOOT_ABI.md](doc/BOOT_ABI.md) | Boot and resume ABI: RAM layout, saved context, CRC, image header, PMU scratch registers (normative) |
| [doc/firmware.md](doc/firmware.md) | Firmware: boot ROM, drivers, power management, validation suite, UART monitor |
| [doc/VERIFICATION.md](doc/VERIFICATION.md) | CPU-subsystem verification flows (pre-integration description) |
| [doc/INTEGRATION_REPORT.md](doc/INTEGRATION_REPORT.md) | Integration stages: merged content, decisions, results |
| [doc/reviews/interface_audit.md](doc/reviews/interface_audit.md) | Cross-branch interface audit (finding IDs Bxx/Wxx) |

## Directory layout

| Path | Contents |
|---|---|
| `rtl/core/`, `rtl/pkg/` | RV32IM 5-stage core (`core_top`), CSR file, decoder, ALU, mul/div, fetch |
| `rtl/cache/` | 4 KB 2-way I-cache, 4 KB 2-way write-back D-cache |
| `rtl/cpu/` | `cpu_top` (core + caches + AXI mux), `pd_cpu` (PD_CPU boundary) |
| `rtl/bus/` | AXI4-Lite 2:1 mux, CDC bridge, 1:N interconnect, register adapter |
| `rtl/aon/` | PMU, UART, machine timer, wake timer, interrupt controller, ROM/RAM front end |
| `rtl/debug/` | Debug blocks: trace buffer, event counters, error log, watchdog, `dbg_subsys` wrapper (PD_AON) |
| `rtl/soc/` | `soc_top`, CPU clock-gate and reset control |
| `rtl/clk/` | Glitch-free DVFS clock multiplexer |
| `rtl/common/` | Reset synchronizer, async FIFO, mtime snapshot crossing |
| `rtl/tech/` | Technology wrappers with generic models (ICG, sync, isolation, power switch, SRAM, two-clock RAM, ROM) |
| `upf/` | IEEE 1801 power intent |
| `fw/` | Firmware, one tree for the SoC and Spike: boot ROM, drivers (incl. debug blocks), power management, validation suite, UART monitor, stage-1 pm_test / boot_test, debug application `fw/debug` (GCC) |
| `tools/` | Image builder (`mkimage.py`), suite-log converter (`fw_results.py`), monitor session checker, crash-dump decoder (`dbg_decode.py`), triage, coverage merger, lab bench (`tools/bench`) |
| `verif/debug/` | Debug-block unit testbenches (SystemVerilog, SVA), UART pty bridge for the bench |
| `sw/` | Directed CPU test programs |
| `sim/` | SoC testbench (`tb_soc.sv`), PMU unit testbench |
| `dv/` | CPU co-simulation (Spike), cache unit benches, arch-test model, regression lists |
| `formal/` | SymbiYosys harnesses: PMU, DVFS mux, async FIFO, mtime crossing |
| `scripts/` | Regression driver and checkers, corruption-model generator, toolchain setup |
| `third_party/riscv-arch-test` | riscv-arch-test 3.9.1 (git submodule) |

## Architecture

```
 PD_AON (clk_aon, always on)                                   PD_CPU (clk_cpu, switchable)
 +---------------------------------------------------+         +----------------------------+
 | PMU  wake timer  mtimer  INTC  UART  ROM  RAM     |         | pd_cpu                     |
 |        AXI4-Lite interconnect (axil_demux)        |  AXI    |  2-flop sync: irq, idle_req|
 |   RAM alias fold   ^                              | <-iso-- |  mtime snapshot (dst)      |
 |                    axil_cdc_bridge  <-------------|         |  cpu_top                   |
 |  idle_req, irq ----------------------------------->|-------->|   core_top (RV32IM, 5 st.) |
 |  mtime snapshot (src) --------------------------->|-------->|   icache, dcache (WB)      |
 |  <- sync <- iso <- idle_ack, core_sleep, cache_clean, mtime_req   axil_mux2              |
 |  dvfs_clk_mux -> ICG -> clk_cpu ------------------>|-------->|                            |
 |  power switch, isolation, reset control            |         +----------------------------+
 +---------------------------------------------------+
```

- Address map (doc/SPEC.md): ROM `0x0000_0000` 16 KB, RAM `0x1000_0000` 128 KB,
  peripherals from `0x2000_0000`, debug blocks `0x2000_8000` (32 KB range),
  uncached RAM alias `0x3000_0000`. Unmapped addresses return SLVERR.
- The CPU caches ROM (I-side) and RAM (I and D). The reset vector and cacheable
  windows are `soc_top` parameters passed to `pd_cpu`.
- Power states RUN, IDLE (clock gated), SLEEP (PD_CPU off), DEEP_SLEEP (SLEEP +
  RAM retention); three DVFS operating points. The PMU powers PD_CPU down only
  while the CPU reports `idle_ack` and `cache_clean` (no dirty D-cache line).
- Cache maintenance: CSR `mcachectl` (0x7C0) only.
- The PMU wakes the CPU only for interrupt sources in its WAKE_MASK, which the
  firmware sets to the sources it enabled in `mie`.
- Debug blocks in PD_AON observe the CPU's retire / trap and cache / stall
  events and the PMU's stable power state; the watchdog's reset request is
  served by the PMU (doc/DEBUG_SPEC.md, doc/SOC_REGMAP.md "Watchdog reset").
- Boot: the boot ROM resumes a saved context (CRC-checked) or cold-boots an
  application image from RAM (doc/BOOT_ABI.md).

## Running

Tools: `scripts/setup_toolchain.sh` installs the pinned versions (Ubuntu 24.04);
`scripts/setup_toolchain.sh --check` verifies them, `--env` prints the PATH.

```bash
git submodule update --init
```

```bash
make test
```

`make test` runs every open-source flow (toolchain check, lint, firmware, CPU
co-simulation, riscv-arch-test, cache benches, CPU coverage gate, SoC
simulations in Verilator and Icarus, SoC negative tests, the firmware
validation suite on the SoC and on Spike, UART monitor sessions, firmware
negative tests, debug-block unit benches, the debug application on the SoC,
the lab bench flow against the SoC simulation, PMU unit test, formal proofs
with cover runs, mutation analysis, checker self-tests). Each step checks
its required-test list in `dv/regress/`; any failure, missing test or unknown
test makes it exit nonzero. Single steps: `make lint`, `make sim`, `make boot`,
`make sim-x`, `make boot-x`, `make sim-neg`, `make fw-suite`, `make fw-spike`,
`make fw-monitor`, `make fw-neg`, `make dbg-unit`, `make dbg-integ`,
`make bench`, `make sim-pmu`, `make cosim`,
`make archtest`, `make cachetest`, `make coverage`, `make formal`,
`make mutation`, `make selftest` (see the `Makefile` header).

Not run by `make test`: UVM (commercial simulators, no UVM content yet) and
UPF-aware simulation (no open-source tool).
