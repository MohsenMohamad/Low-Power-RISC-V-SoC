# Low-Power RISC-V SoC — Specification

## Architecture
- CPU: in-house RV32IM, 5-stage pipeline, forwarding, hazard stalls, branch flush,
  machine-mode CSRs, interrupts/exceptions, WFI.
- Caches: 4 KB I-cache and 4 KB D-cache, 2-way set-associative, write-back D-cache.
- Bus: AXI4-Lite interconnect.
- Memories: 16 KB boot ROM, 128 KB RAM (in PD_AON, retained).
- Peripherals: UART, machine timer (mtime/mtimecmp), wake timer, interrupt controller, PMU.
- Technology-specific cells (clock gate, clock mux, power switch, isolation,
  synchronizers, RAM macros) are instantiated only through thin wrapper modules
  with generic simulation models, so FPGA and ASIC versions can be swapped in later.
- The PicoRV32-based platform is not part of the design. It may not be used in the
  SoC top, in firmware platform code, or as a test target.

## Address map
| Region | Base | Size | Cacheable |
|---|---|---|---|
| Boot ROM | 0x0000_0000 | 16 KB | yes (I-side) |
| RAM | 0x1000_0000 | 128 KB | yes |
| UART | 0x2000_0000 | 4 KB | no |
| Machine timer | 0x2000_1000 | 4 KB | no |
| Interrupt controller | 0x2000_2000 | 4 KB | no |
| PMU | 0x2000_3000 | 4 KB | no |
| Wake timer | 0x2000_4000 | 4 KB | no |
| Debug blocks | 0x2000_8000 | 32 KB | no |
| RAM uncached alias | 0x3000_0000 | 128 KB | no |

- The RAM uncached alias maps to the same physical RAM as 0x1000_0000 and bypasses
  the D-cache. It is used for state shared with the host or across reboots.
- CPU reset vector: 0x0000_0000. The CPU's reset vector, RAM base and cacheable
  ranges are parameters set from this table, never hard-coded.
- Unmapped addresses return SLVERR.

## Register maps
- doc/SOC_REGMAP.md is normative for every SoC register map (UART, machine timer,
  interrupt controller, PMU, wake timer). Firmware, UVM register models and Python
  tools use it unchanged. Any change goes into doc/SOC_REGMAP.md first.
- doc/DEBUG_SPEC.md is normative for the debug blocks and must use the debug range above.

## Cache maintenance
- The only maintenance interface is the CPU CSR mcachectl (0x7C0). There is no
  memory-mapped cache controller.
- A clean or flush operation reports completion only after every dirty line has been
  written back and its AXI write response received without error. An error is
  reported to software.
- Cache statistics come from the debug event counters.

## CPU <-> SoC interface
- Defined in doc/CPU_SOC_INTERFACE.md: every port, width, clock domain and handshake.
- Power handshake:
  - idle_req (PMU -> CPU): request to quiesce.
  - idle_ack (CPU -> PMU): pipeline drained, no outstanding bus transaction.
  - cache_clean (CPU -> PMU): the D-cache holds no dirty lines.
  - "Caches idle" never substitutes for cache_clean.
  - The PMU powers down PD_CPU only while idle_ack and cache_clean are both asserted.
- Interrupts follow the RISC-V privileged specification: WFI resumes on an interrupt
  that is pending and enabled in mie. Firmware enables in mie every source it uses
  as a wake source.
- mtime is exported from PD_AON to the CPU with a safe clock-domain crossing.
- Each interrupt signal entering PD_CPU is synchronized exactly once, at the
  CPU boundary.

## Power domains and clocks
- PD_AON (always on, clk_aon): PMU, wake timer, machine timer, interrupt controller,
  RAM, UART, debug blocks.
- PD_CPU (switchable, clk_cpu from DVFS): CPU core and caches.
- clk_aon and clk_cpu are asynchronous; every crossing uses proper synchronizers,
  handshakes, or async FIFOs.
- CPU power states: RUN, IDLE (clock gated on WFI), SLEEP (power off, architectural
  state saved by firmware to RAM), DEEP_SLEEP (SLEEP + RAM retention mode).
- Power-down: firmware saves context + cleans D-cache -> WFI -> PMU: idle handshake ->
  clock gate -> isolation on -> switch off. Wake: interrupt -> switch on -> power_good ->
  reset release -> isolation off -> clock on -> boot ROM detects resume -> restore context.
- DVFS: 3 operating points for clk_cpu via glitch-free clock mux; change only in IDLE.
- IEEE 1801 UPF file for both domains.

## Boot and resume ABI
- Defined in doc/BOOT_ABI.md: context-save layout and address, resume magic,
  CRC, image header, and which PMU scratch registers hold the context pointer and magic.
- The boot ROM restores context only if its CRC matches; otherwise it cold-boots.

## Firmware (bare-metal C)
- Boot ROM: cold boot vs resume detection, context restore.
- Drivers: UART, timers, interrupt controller, PMU, cache maintenance, debug blocks.
- Validation suite (self-checking): CSR, exceptions, interrupts, cache coherence with
  clean, all power-state transitions, DVFS changes, sleep/wake stress loops.
- Bring-up monitor over UART: memory/register peek/poke, run test by ID.

## Verification
- Primary methodology: SystemVerilog.
  - SVA for protocols (AXI4-Lite), PMU sequencing, isolation clamps, CDC handshakes.
  - Class-based SystemVerilog testbenches with constrained random (randomize())
    and cover properties, runnable with Verilator --timing.
  - UVM (IEEE 1800.2) verification IP under verif/uvm/ for subsystem-level
    verification, run on a commercial simulator (Xcelium / VCS / Questa).
- CPU: lockstep co-simulation against Spike on random instruction streams;
  riscv-arch-test compliance suite.
- Caches: random traffic vs a memory reference model, eviction/clean scenarios.
- PMU: formal proofs (SymbiYosys), OFF-state corruption model on the real CPU domain,
  full power-state transition coverage.
- cocotb tests are kept only as a fast smoke regression; no new cocotb tests.
- Python is used for regression, triage, coverage merging and automation, not for
  testbenches.
- Verilator lint clean. A single top-level `make test` runs everything that runs on
  open-source tools.

## Verification rules
- Any failure, error, timeout or crash produces a nonzero exit code at every level:
  test, runner, top-level `make test`, CI.
- Each regression has a required-test list. A required test that is missing,
  not run, or skipped counts as a failure. Unknown test IDs are a failure.
- A test result is never overwritten: one FAIL for an ID fails the run.
- A power test passes only if the requested transition actually completed.
  An aborted transition is reported as ABORTED and is never counted as a pass or
  as coverage.
- Coverage holes against the defined coverage goals fail the build unless listed
  with a reason in a waiver file.
- A mutation run fails if any mutant survives or fails to build, unless waived
  with a reason.
- Every checker, scoreboard, comparator and result parser has a negative test that
  proves it reports failure on wrong input.
- Every formal proof has a cover run proving its assumptions are not vacuous.
- Assertions may not be disabled by the condition they are meant to check.
- Every published number (pass rates, coverage, latency) must be reproducible by a
  command documented next to it.

## Toolchain
- One setup script records exact versions of every tool; CI uses the same script.
- RISC-V compiler: GCC 13.2 with binutils 2.42, -march=rv32im_zicsr_zifencei
  -mabi=ilp32, no compressed instructions.
- Verilator, Spike (pinned commit), Yosys/SymbiYosys and Icarus: exact versions in
  the setup script.

## FPGA (later stage)
- Synthesizable for FPGA; power switching emulated by holding PD_CPU in reset and
  gating its clock.

## Rules
- Synthesizable SystemVerilog only. README is technical documentation only.
- If a tool cannot run in the environment, report it; never fake results.
