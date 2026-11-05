# CPU <-> SoC interface

Normative for the boundary between the switchable CPU domain (PD_CPU) and the
always-on domain (PD_AON). Required by doc/SPEC.md ("CPU <-> SoC interface").
Implemented in `rtl/cpu/pd_cpu.sv` (PD_CPU side) and `rtl/soc/soc_top.sv`
(PD_AON side). Audit findings resolved here: B09, B10, W02, W03, W05, W06, W35.

## Hierarchy

```
soc_top (PD_AON, clk_aon)
 |- u_dvfs_mux    clk_op[2:0] -> clk_cpu_root (glitch-free)
 |- u_clk_rst     ICG: clk_cpu_root -> clk_cpu; CPU reset generation
 |- u_pwr_sw      PD_CPU power switch
 |- u_mtime_src   mtime snapshot crossing, source half
 |- u_iso         isolation (clamp 0) of every PD_CPU output
 |- u_bridge      AXI4-Lite CDC bridge (clk_cpu -> clk_aon)
 |- u_core_sync   idle_ack / core_sleep / cache_clean -> clk_aon
 |- u_aon         interconnect, ROM, RAM, UART, timers, INTC, PMU
 '- u_pd_cpu      pd_cpu  (PD_CPU, clk_cpu)            <- this interface
     |- u_async_sync   the only synchronizer for meip/mtip/msip/idle_req
     |- u_mtime_dst    mtime snapshot crossing, destination half
     '- u_cpu          cpu_top: core_top, icache, dcache, axil_mux2
```

Everything below `u_pd_cpu` is PD_CPU in `upf/soc_top.upf`; everything else is
PD_AON.

## Parameters of `pd_cpu` (set by `soc_top` from the doc/SPEC.md address map)

| Parameter | Value | Meaning |
|---|---|---|
| `BOOT_ADDR` | `0x0000_0000` | CPU reset vector (`boot_addr_i` of `cpu_top`) |
| `ROM_BASE` / `ROM_MASK` | `0x0000_0000` / `0xFFFF_C000` | Boot ROM, 16 KB, cacheable in the I-cache |
| `RAM_BASE` / `RAM_MASK` | `0x1000_0000` / `0xFFFE_0000` | RAM, 128 KB, cacheable in I- and D-cache |

An address is cacheable when `(addr & MASK) == BASE`. Every other address,
including the RAM uncached alias `0x3000_0000` (`soc_top.RAM_ALIAS_BASE`), is
accessed uncached: one AXI4-Lite transaction per access, with byte strobes for
stores. `soc_top` passes the same values to `aon_subsys`, which decodes the
alias onto the RAM, so the CPU and the decoder cannot disagree.

## Port list of `pd_cpu`

Clock domain "async" means the signal is produced in another clock domain and
is only used behind a synchronizer.

| Port | Dir | Width | Clock domain | Description |
|---|---|---|---|---|
| `clk_i` | in | 1 | - | `clk_cpu`: DVFS-muxed clock, gated by the PMU (ICG in PD_AON) |
| `rst_ni` | in | 1 | async assert, release sync. to `clk_cpu_root` | CPU reset, active low (see Reset) |
| `meip_i` | in | 1 | async (clk_aon) | Machine external interrupt (INTC output), level |
| `mtip_i` | in | 1 | async (clk_aon) | Machine timer interrupt, level |
| `msip_i` | in | 1 | async (clk_aon) | Machine software interrupt, level |
| `idle_req_i` | in | 1 | async (clk_aon) | PMU requests quiescence (4-phase handshake) |
| `idle_ack_o` | out | 1 | clk_cpu, flop output | Core is quiescent and stays so while `idle_req` is high |
| `core_sleep_o` | out | 1 | clk_cpu, flop output | In WFI, drained, caches and bus idle, no enabled interrupt pending |
| `cache_clean_o` | out | 1 | clk_cpu, flop output | The D-cache holds no dirty line and no write-back is in flight |
| `mtime_snap_i` | in | 64 | clk_aon, quasi-static | mtime snapshot (see mtime) |
| `mtime_ack_i` | in | 1 | async (clk_aon) | Snapshot acknowledge toggle |
| `mtime_req_o` | out | 1 | clk_cpu, flop output | Snapshot request toggle |
| `m_aw*` / `m_w*` / `m_b*` / `m_ar*` / `m_r*` | | | clk_cpu | AXI4-Lite master (below) |

AXI4-Lite master: `m_awvalid_o`, `m_awready_i`, `m_awaddr_o[31:0]`,
`m_awprot_o[2:0]`, `m_wvalid_o`, `m_wready_i`, `m_wdata_o[31:0]`,
`m_wstrb_o[3:0]`, `m_bvalid_i`, `m_bready_o`, `m_bresp_i[1:0]`, `m_arvalid_o`,
`m_arready_i`, `m_araddr_o[31:0]`, `m_arprot_o[2:0]`, `m_rvalid_i`,
`m_rready_o`, `m_rdata_i[31:0]`, `m_rresp_i[1:0]`. Single-beat transfers; the
I-cache and D-cache masters are arbitrated by `axil_mux2`, at most one read
and one write in flight. `AxPROT` = 001 (data), 101 (instruction). A response
with `xRESP[1] = 1` (SLVERR, DECERR) is an error: a load / store access fault
for uncached and refill accesses, an imprecise write-back error otherwise.

Every output is isolated in PD_AON (`u_iso`, clamp value 0) while
`iso_en` is high. Inputs need no isolation. No output of PD_CPU is used in
PD_AON without first passing either the isolation cell and a synchronizer
(`idle_ack`, `core_sleep`, `cache_clean`, `mtime_req`) or the isolation cell
and the AXI CDC bridge.

## Clock-domain crossings at the boundary

| Signal | Direction | Synchronizer (location) | Why it is safe |
|---|---|---|---|
| `meip`, `mtip`, `msip` | AON -> CPU | `pd_cpu.u_async_sync`, 2 flops | Levels; each bit independent. Synchronized exactly once (W05): nothing in PD_AON synchronizes them towards the CPU, nothing inside `cpu_top` synchronizes them again (`core_csr` registers the already synchronous level into `mip`) |
| `idle_req` | AON -> CPU | `pd_cpu.u_async_sync`, 2 flops | Level of a 4-phase handshake |
| `idle_ack`, `core_sleep`, `cache_clean` | CPU -> AON | `soc_top.u_core_sync`, 2 flops | Flop outputs (glitch-free), levels; `idle_ack` is a 4-phase handshake |
| `mtime[63:0]` | AON -> CPU | snapshot handshake (below) | Data never passes a synchronizer; it is stable when sampled |
| `mtime_req` / `mtime_ack` | both | 2 flops each side | Toggle signals |
| AXI4-Lite | CPU -> AON | `axil_cdc_bridge`, one Gray-pointer async FIFO per channel | |
| `cg_en` / `cg_ack`, CPU reset / `cpu_rst_ack` | AON <-> clk_cpu_root | `cpu_clk_rst_ctrl` | see Reset and clock ownership |

## Power handshake (doc/SPEC.md)

| Signal | Meaning |
|---|---|
| `idle_req` (PMU -> CPU) | Request to quiesce. Raised by the PMU after it saw `core_sleep` with `CTRL.LP_EN` set. |
| `idle_ack` (CPU -> PMU) | Pipeline drained and no outstanding bus transaction: WFI has retired, the fetch unit has no request in flight, EX/MEM/WB are empty, the I-cache, the D-cache and the AXI mux are idle. |
| `cache_clean` (CPU -> PMU) | The D-cache holds no dirty line (and no eviction write-back is in flight). |

Rules:

1. `idle_ack` rises only while `idle_req` (synchronized) is high and the core
   is quiescent (`cpu_top.quiescent`). Once high it stays high until
   `idle_req` falls; it falls one `clk_cpu` cycle later.
2. While `idle_req` is high, or `idle_ack` is still high, the core does not
   leave WFI, even if an enabled interrupt is pending (`core_top.wfi_hold_i`).
   So an acknowledged core issues no fetch and no AXI transaction until the PMU
   withdraws the request (W03). Checked by the assertion
   `cpu_top.a_ack_quiescent` and by the co-simulation testbench, which drives
   random handshakes with interrupt races and fails on any commit or AXI
   request while `idle_ack` is high.
3. If an interrupt ends WFI before the core acknowledges, `core_sleep` falls
   and the PMU aborts the entry (`IDLE_REQ -> WAKE_REL`).
4. The PMU gates `clk_cpu` only after the handshake completed
   (`pmu.a_gate_needs_handshake`), and powers PD_CPU down only while
   `idle_ack` and `cache_clean` are both asserted and the bus bridge is idle
   (`BUS_DRAIN -> ISO_ON`, `pmu.a_iso_on_bus_idle`). Otherwise it refuses
   (`BUS_DRAIN -> IDLE`, `STATUS.ERR_DIRTY`), the CPU stays powered and clock
   gated until the wake event.
5. "Caches idle" never substitutes for `cache_clean` (W02): `cache_clean` is
   computed from the dirty bits, not from the cache FSM state. The
   `caches_idle_o` output of `cpu_top` is a status signal only and is not
   connected to the PMU.
6. `core_sleep` = WFI retired, drained, both caches and the AXI mux idle, and
   no interrupt pending and enabled in `mie`. WFI follows the RISC-V
   privileged specification: it ends on an interrupt that is pending and
   enabled in `mie`, regardless of `mstatus.MIE`. The PMU wakes on any of
   `meip | mtip | msip`; firmware enables in `mie` every source it uses as a
   wake source.

## `cache_clean` and cache maintenance completion (W35)

The only maintenance interface is CSR `mcachectl` (0x7C0): bit 0 flush
(clean + invalidate), bit 1 I-cache invalidate, bit 2 clean; bit 31 reads the
write-back error flag. A write to `mcachectl` stalls in WB until the
operation completed.

- A clean or flush writes back each dirty line as four single-beat AXI
  writes and waits for each write response. The line's dirty bit is cleared
  (and, for flush, its valid bit) only after the fourth response arrived, and
  only if none of the four responses was an error. A line whose write-back
  failed stays valid and dirty: `cache_clean` stays low, the next clean or
  flush retries it.
- Completion is reported (the CSR write retires) after the scan of all sets and
  ways, i.e. after every write response. Bit 31 then reads 1 if any write-back
  of this operation failed, or if an eviction write-back failed since the
  previous maintenance operation (the evicted data is lost; it is reported once,
  by the next operation). Firmware checks bit 31 after the clean and abandons a
  low-power entry if it is set (`fw/crt0.S`, `pm_suspend` returns -1).
- `cache_clean` is a flop output that is low from the cycle a cacheable store
  is accepted, while any valid line is dirty, and while an eviction write-back
  is in flight.

## mtime export (B10)

`aon_mtimer` exports its live 64-bit counter (`mtime_o`, clk_aon).
`cdc_snapshot_src` (PD_AON) and `cdc_snapshot_dst` (PD_CPU) move a coherent
copy to the CPU's `mtime_i` with a toggle handshake:

1. The destination toggles `mtime_req`.
2. The source sees the synchronized toggle, captures `mtime` into `snap_q`, and
   toggles `mtime_ack` in the same cycle.
3. The destination sees the synchronized acknowledge (2 `clk_cpu` cycles
   later, so `snap_q` has been stable for at least that long), copies
   `snap_q` into its output register and immediately requests the next
   snapshot.

The 64-bit value never passes through a synchronizer, so the CPU never sees a
torn value; it lags the AON counter by roughly 2 `clk_aon` + 3 `clk_cpu`
cycles and is monotonic. `time`/`timeh` read this value (`core_csr`). After a
CPU reset the first handshake only primes the protocol; while PD_CPU is off
`mtime_req` is isolated to 0, so the source's acknowledge also settles to 0
before the CPU is released, and no pre-power-down snapshot is used.

## Reset and clock ownership (W06)

| Item | Owner | Behaviour |
|---|---|---|
| `clk_cpu_root` | PD_AON, `dvfs_clk_mux` | Glitch-free mux of the three operating-point clocks; the PMU switches it only while `clk_cpu` is gated |
| `clk_cpu` | PD_AON, `cpu_clk_rst_ctrl` (ICG) | Gated by the PMU (`cg_en`, synchronized into `clk_cpu_root`; `cg_ack` returned to clk_aon) |
| `rst_ni` of `pd_cpu` | PD_AON, `cpu_clk_rst_ctrl.u_cpu_rst` | Asserted asynchronously by POR or the PMU (`cpu_rst_req_n`); released synchronously to the free-running `clk_cpu_root`, so release does not need the gated clock. The released state is synchronized back to clk_aon as `cpu_rst_ack` |
| AXI bridge, slave side | PD_AON | Clocked by `clk_cpu`, reset only by POR: FIFO pointers survive CPU power cycles |

Sequence (PMU, `rtl/aon/pmu.sv`):

- Power-down: idle handshake -> clock gated (`cg_ack` low) -> (SLEEP)
  `idle_ack` and `cache_clean` and bus idle -> isolation on and CPU reset
  asserted -> switch off.
- Wake: switch on -> `power_good` -> reset-clocking window (`RST_CLK_CYCLES`
  clocks with reset held and isolation on; the in-house core uses asynchronous
  reset, so the window is not needed by it but is harmless) -> reset release ->
  wait for `cpu_rst_ack` -> isolation off -> clock on (`cg_ack`) -> `idle_req`
  withdrawn -> wait for `idle_ack` low -> RUN.

All CPU state flops that need a defined value after power-up use an
asynchronous active-low reset (`core_top`, `core_csr`, caches, mux,
`cpu_top`, `pd_cpu` synchronizers, `cdc_snapshot_dst`); pipeline data
registers and SRAM contents are qualified by reset-cleared valid bits. The
OFF-state corruption model (`scripts/gen_corrupt.sh`) overwrites every one of
these state elements and SRAM words when the supply drops and again at
power-up, so any dependence on retained or reset-free state shows up in
`make sim` / `make sim-x`.

## Boot and resume (stage-1 firmware ABI)

The reset vector is the boot ROM base. The interim resume protocol used by
`fw/crt0.S` (context with CSRs, CRC-32, PMU SCRATCH0/1) is described at the
top of that file; doc/BOOT_ABI.md is a later-stage item (see
doc/INTEGRATION_REPORT.md).
