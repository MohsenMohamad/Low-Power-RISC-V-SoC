# Low-Power RISC-V SoC

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
dv/cache     SystemVerilog class-based constrained-random cache testbenches
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
| `make cachetest` | SV cache testbenches (`dv/cache`, `SEEDS`, `N`) |
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
