# Low-Power RISC-V SoC

Specification: [`doc/SPEC.md`](doc/SPEC.md).

This repository currently contains the bare-metal firmware and the
PicoRV32-based bring-up version of the SoC that runs it:

- [`doc/firmware.md`](doc/firmware.md): boot ROM, drivers, sleep/resume
  path, validation suite, UART monitor.
- [`doc/picorv32_platform.md`](doc/picorv32_platform.md): bring-up SoC.
  It has PD_CPU/PD_AON, the PMU with IDLE/SLEEP/DEEP_SLEEP and DVFS,
  caches, CDC bridge and technology-cell wrappers.

## Layout

```
doc/                  specification and technical documentation
fw/                   firmware (boot ROM, drivers, pm, tests, monitor)
rtl/tech/             technology-cell wrappers with generic simulation models
platform/picorv32/    PicoRV32-based SoC RTL, testbench, monitor session specs
third_party/picorv32/ PicoRV32 (ISC), with a one-line patch exporting wfi
tools/                image tool, monitor session checker, test runner
```

## Requirements

| Tool | Used for | Tested version |
|------|----------|----------------|
| `riscv64-unknown-elf-gcc` (multilib rv32im/ilp32) | firmware | 13.2.0 |
| Verilator | SoC simulation and lint | 5.020 |
| Spike (`riscv-isa-sim`) | ISA-level runs; `$SPIKE`, `PATH` or `/opt/spike/bin/spike` | master `f90d5af` |
| Python 3 | tools | 3.x |

## Usage

```bash
make test
```

`make test` builds the firmware (3 configurations), lints and builds the
SoC simulation, then runs:

- the validation suite on the PicoRV32 SoC and on Spike;
- scripted UART monitor sessions;
- a self-test proving that failures are reported.

Results are in `build/test/summary.txt`. Steps whose tools are missing are
reported as SKIPPED.

Other targets: `make fw`, `make sim`, `make lint`, `make clean`.
