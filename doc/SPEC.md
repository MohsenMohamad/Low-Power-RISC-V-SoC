# Low-Power RISC-V SoC — Specification

## Architecture
- CPU: in-house RV32IM, 5-stage pipeline, forwarding, hazard stalls, branch flush,
  machine-mode CSRs, interrupts/exceptions, WFI.
- Caches: 4 KB I-cache and 4 KB D-cache, 2-way set-associative, write-back D-cache,
  fence/flush support (required before power-down).
- Bus: AXI4-Lite interconnect.
- Memories: 16 KB boot ROM, 128 KB RAM (in PD_AON, retained).
- Peripherals: UART, machine timer (mtime/mtimecmp), interrupt controller.
- Technology-specific cells (clock gate, clock mux, power switch, isolation,
  synchronizers, RAM macros) are instantiated only through thin wrapper modules
  with generic simulation models, so FPGA and ASIC versions can be swapped in later.

## Power domains and clocks
- PD_AON (always on, clk_aon): PMU, wake timer, interrupt controller, RAM, UART.
- PD_CPU (switchable, clk_cpu from DVFS): CPU core and caches.
- clk_aon and clk_cpu are asynchronous; every crossing uses proper synchronizers,
  handshakes, or async FIFOs.
- CPU power states: RUN, IDLE (clock gated on WFI), SLEEP (power off, architectural
  state saved by firmware to RAM), DEEP_SLEEP (SLEEP + RAM retention mode).
- Power-down: firmware saves context + flushes D-cache -> WFI -> PMU: clock gate ->
  isolation on -> switch off. Wake: interrupt -> switch on -> power_good -> reset
  release -> isolation off -> clock on -> boot ROM detects resume -> restore context.
- DVFS: 3 operating points for clk_cpu via glitch-free clock mux; change only in IDLE.
- IEEE 1801 UPF file for both domains.

## Verification
- Primary methodology: SystemVerilog.
  - SVA for protocols (AXI4-Lite), PMU sequencing, isolation clamps, CDC handshakes.
  - Class-based SystemVerilog testbenches with constrained random (randomize())
    and cover properties, runnable with Verilator --timing.
  - UVM (IEEE 1800.2) verification IP under verif/uvm/ for subsystem-level
    verification, run on a commercial simulator (Xcelium / VCS / Questa).
- CPU: lockstep co-simulation against Spike (via DPI) on random instruction streams;
  riscv-arch-test compliance suite.
- Caches: random traffic vs a memory reference model, eviction/flush scenarios.
- PMU: formal proofs (SymbiYosys), OFF-state corruption model, full power-state
  transition coverage.
- cocotb tests are kept only as a fast smoke regression in CI; no new cocotb tests.
- Python is used for regression, triage, coverage merging and automation, not
  for testbenches.
- Verilator lint clean; `make test` runs everything that runs on open-source tools.

## Firmware (bare-metal C)
- Boot ROM: cold boot vs resume detection, context restore.
- Drivers: UART, timer, interrupt controller, PMU, cache maintenance.
- Validation suite (self-checking, pass/fail signature): CSR, exceptions, interrupts,
  cache coherence with flush, all power-state transitions, DVFS changes,
  sleep/wake stress loops.
- Bring-up monitor over UART: memory/register peek/poke, run test by ID.

## FPGA (later stage)
- Synthesizable for FPGA; power switching emulated by holding PD_CPU in reset and
  gating its clock.

## Rules
- Synthesizable SystemVerilog only. README is technical documentation only.
- If a tool cannot run in the environment, report it; never fake results.
