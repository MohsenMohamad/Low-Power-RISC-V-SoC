# PicoRV32-based bring-up SoC

`platform/picorv32/` is a version of the SoC used to run the firmware in
RTL simulation before the in-house core exists. It has the SoC's memory
map, power domains, PMU sequencing and peripherals, with PicoRV32 standing
in for the CPU. It is synthesizable SystemVerilog, apart from the
testbench and the code under `ifndef SYNTHESIS`.

## Structure

```
pico_soc
├── clock generation    clk_ref, /2, /4 -> tc_clk_mux_gf -> tc_clk_gate -> clk_cpu
├── tc_pwr_switch       PD_CPU switch + power-good, tc_vreg (voltage select)
├── pico_pd_cpu         PD_CPU (clk_cpu)
│   ├── picorv32        RV32IM, IRQ + q-registers, counters (vendored, +wfi output)
│   ├── pico_cache x2   4 KB 2-way, 16 B lines, 128 sets; D$ write-back/allocate
│   ├── cache registers 0x5000_0000
│   └── bus_cdc_cpu     CPU half of the async bridge
├── tc_iso              clamp-to-0 isolation of all PD_CPU outputs
└── PD_AON (clk_aon)
    ├── bus_cdc_aon     AON half (reset while isolated)
    ├── boot ROM, RAM   tc_sram (RAM has the retention input)
    ├── aon_uart        8N1, 16-deep FIFOs
    ├── aon_timer       mtime/mtimecmp/msip, CLINT layout, prescaler
    ├── aon_intc        8 level sources -> MEIP
    └── aon_pmu         power sequencer, DVFS, reset cause, counters
```

Differences from the target SoC:

| Area | Target SoC (`doc/SPEC.md`) | This platform |
|------|----------------------------|---------------|
| CPU | in-house 5-stage pipeline with M-mode CSRs | PicoRV32: custom IRQ scheme, no CSR file |
| Bus | AXI4-Lite | single-word valid/ready |
| Wake/sleep signal | WFI | PicoRV32 `waitirq` (exported as `wfi`) |

The firmware hides the CPU difference behind `fw/arch/`.

## Clocks and crossings

- clk_aon (testbench: 32.26 MHz) drives PD_AON, mtime and the PMU.
- clk_ref (testbench: 100 MHz) feeds a divider (/1, /2, /4). A glitch-free
  3-input mux selects the operating point, and an ICG produces clk_cpu.
- The ICG enable is synchronized in the mux-output clock domain. Its
  synchronized value is the clock-gate acknowledge sent back to the PMU.
- The CPU↔AON bus crossing is a two-phase toggle handshake with bundled
  data. Interrupt lines, `wfi`, gate acknowledge and the mux `active`
  signals all go through 2-flop synchronizers.

## Power sequencing (aon_pmu)

| Sequence | Steps |
|----------|-------|
| IDLE | WFI and no interrupt pending → gate clk_cpu → wait for any interrupt → ungate |
| SLEEP | WFI → gate → isolation on → reset → switch off (wait for power-good low) → OFF |
| DEEP_SLEEP | as SLEEP, then RAM retention on |
| Wake | wake source (`WAKE_EN` & {MEIP, MSIP, MTIP}) → [retention off + delay] → switch on → power_good → reset release → isolation off → clock on |
| DVFS | at the gated point: raise VSEL (wait `vok`) → switch mux (wait `active`) → lower VSEL → `DVFS_DONE` event → ungate |
| Abort | a sleep request with an interrupt pending, or with no wake source, is turned into an ungate. `CNT_ABORT` and `EVENT.SLEEP_ABORTED` record it. |
| Software reset | key write → wait for an idle bus → reset PD_CPU for 16 cycles → `RST_CAUSE = SWRST` |

Register map: `fw/include/soc.h` and the header comment of
`rtl/aon_pmu.sv`. Simulation-only checks in the PMU flag:

- PD_CPU unpowered without isolation;
- PD_CPU unpowered while out of reset;
- RAM in retention while PD_CPU is powered.

### OFF-state corruption model (simulation)

When the PD_CPU supply drops (`tc_pwr_switch.pwr`):

- the cache tag and data arrays (`tc_sram`) are filled with random data;
- the PicoRV32 register file, including the q-registers, is filled with
  random data;
- flip-flops are held in reset.

Firmware that relied on any PD_CPU state across SLEEP would fail. Test 46
shows the effect: without the D$ flush, the boot ROM rejects the stale
context.

## Technology wrappers (`rtl/tech/`)

`tc_sync`, `tc_rst_sync`, `tc_clk_gate`, `tc_clk_mux_gf`, `tc_iso`,
`tc_pwr_switch`, `tc_vreg`, `tc_sram`. Each one has a generic model; the
FPGA and ASIC versions replace the module body.

## Testbench (`tb/tb_top.sv`)

| Plusarg | Meaning |
|---------|---------|
| `+rom_hex=` / `+ram_hex=` | preload ROM / RAM (`$readmemh`, word wide) |
| `+test=<id>` | test for the firmware to run (default: all) |
| `+monitor` | start the UART monitor instead |
| `+uart_in=<file>` | UART RX input. Each line is sent after the prompt `mon> `, or after `zzz> ` with a `+wake_delay` hold-off. |
| `+uart_log=<file>` | copy of UART TX |
| `+timeout=<n>` | fail after n clk_aon cycles |
| `+pmu_trace` | print PMU state transitions and `waitirq` state while a sleep mode is armed |
| `+clk_probe` | print clk_cpu / clk_aon edge counts every 1 ms |

Simulation-control device at `0x4F00_0000`:

- `EXIT`: 0 = pass, otherwise the fail code;
- `ARG`: boot argument;
- `PUTC`;
- `TIME`.

The testbench fails the run on PicoRV32 trap (halt), on timeout, and on
UART framing errors.

```bash
make -C platform/picorv32 sim
```

```bash
make -C platform/picorv32 lint
```

`sim` builds `build/picorv32/obj/Vtb_top`; `lint` runs Verilator `-Wall`
on the SoC RTL. PicoRV32 itself is waived in `lint.vlt`.
