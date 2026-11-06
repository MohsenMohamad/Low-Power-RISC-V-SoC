# SoC Register Map

Source of truth: the RTL in `rtl/aon/`. The C definitions are in
`fw/include/soc.h`. All registers are 32 bits wide and sit in PD_AON
(clk_aon), so their contents survive SLEEP and DEEP_SLEEP. Unless noted,
registers take full-word writes only. A partial write (`wstrb != 0xF`) to a
register that requires full words, a write to a read-only register, or an
access to an unmapped offset returns SLVERR, and the register keeps its value.
An access to an unmapped address region returns SLVERR (doc/SPEC.md).

Access types: RW = read/write, RO = read-only, W1C = write 1 to clear,
WO = write-only.

## Memory map

| Base          | Size   | Block                                    |
|---------------|--------|------------------------------------------|
| `0x0000_0000` | 16 KB  | Boot ROM (reset vector `0x0000_0000`)    |
| `0x1000_0000` | 128 KB | Main RAM (retained in SLEEP; retention mode in DEEP_SLEEP) |
| `0x2000_0000` | 4 KB   | UART                                     |
| `0x2000_1000` | 4 KB   | Machine timer (mtime / mtimecmp / msip)  |
| `0x2000_2000` | 4 KB   | Interrupt controller                     |
| `0x2000_3000` | 4 KB   | PMU                                      |
| `0x2000_4000` | 4 KB   | Wake timer                               |
| `0x2000_8000` | 4 KB   | Debug: trace buffer (doc/DEBUG_SPEC.md section 5) |
| `0x2000_9000` | 4 KB   | Debug: event counters (doc/DEBUG_SPEC.md section 6) |
| `0x2000_A000` | 4 KB   | Debug: error log (doc/DEBUG_SPEC.md section 7) |
| `0x2000_B000` | 4 KB   | Debug: watchdog (doc/DEBUG_SPEC.md section 8) |
| `0x2000_C000` | 16 KB  | Debug range, reserved: SLVERR |
| `0x3000_0000` | 128 KB | Main RAM, uncached alias                 |

The CPU caches the boot ROM (I-side) and the main RAM window
`0x1000_0000`-`0x1001_FFFF` (I- and D-side); nothing else is cacheable.

The uncached alias `0x3000_0000`-`0x3001_FFFF` maps to the same physical RAM
as `0x1000_0000`: offset `x` in the alias is offset `x` in the RAM. Accesses
through the alias bypass the D-cache, so they see memory, not dirty cache
lines. Use it for state shared with the host or kept across reboots. Before
reading through the alias data that was written through the cached window,
clean the D-cache (`mcachectl`); after writing through the alias, flush
(clean + invalidate) the D-cache before reading the same data through the
cached window. RAM retention rules apply to both windows.

The debug range `0x2000_8000`-`0x2000_FFFF` (32 KB, doc/SPEC.md) holds the
four debug blocks; their registers are specified in doc/DEBUG_SPEC.md, which
is normative for them. They follow the access rules above (full-word
accesses; partial writes, read-only and unmapped offsets: SLVERR).

ROM writes return SLVERR. RAM accesses while the RAM is in retention return
SLVERR. This cannot happen from the CPU, which is powered off whenever the RAM
is in retention.

## Interrupt routing

| CPU interrupt | Source                                     |
|---------------|--------------------------------------------|
| meip          | Interrupt controller output (`ACTIVE != 0`) |
| mtip          | Machine timer (`mtime >= mtimecmp`)        |
| msip          | Machine timer `MSIP[0]`                    |

The PMU wake event is `(meip & WAKE_MASK[0]) | (mtip & WAKE_MASK[1]) |
(msip & WAKE_MASK[2])` (PMU register WAKE_MASK). An interrupt that is enabled
at its source (and, for meip, in the interrupt controller) and in WAKE_MASK
wakes the CPU from IDLE, SLEEP and DEEP_SLEEP. Firmware sets WAKE_MASK to the
sources it enabled in `mie` before every WFI: a pending interrupt that is not
enabled in `mie` cannot end WFI, so it must not wake the PMU either (otherwise
the PMU would ungate the clock, find the core still in WFI and enter IDLE
again, repeatedly). A source enabled in `mie` but masked in WAKE_MASK is never
woken from IDLE / SLEEP / DEEP_SLEEP.

Interrupt controller source numbers:

| Bit | Source                                            |
|-----|---------------------------------------------------|
| 0   | UART (`aon_uart` irq)                             |
| 1   | Wake timer (`STATUS.EXPIRED`)                     |
| 2   | PMU (`STATUS.DVFS_DONE & IRQ_EN.DVFS_DONE`)       |
| 3   | External wake pin `ext_wake_i` (synchronized level) |
| 4   | Debug error log (`dbg_errlog`: `STATUS & IRQ_EN != 0`, doc/DEBUG_SPEC.md section 7) |
| 5   | Watchdog bark (`dbg_wdt`: `STATUS.BARK & CTRL.BARK_EN`, doc/DEBUG_SPEC.md section 8) |
| 7:6 | Reserved, read as 0                               |

All sources are level-sensitive. Each source is cleared at its origin.

## UART: `0x2000_0000`

8N1. TX and RX FIFOs are 8 entries deep. The baud rate is clk_aon / DIV.

| Offset | Name   | Type | Bits    | Description |
|--------|--------|------|---------|-------------|
| 0x00   | TXDATA | WO / RO | [7:0] W | Write pushes one byte to the TX FIFO. The byte is dropped if the FIFO is full. Byte writes are allowed. |
|        |        |      | [31] R  | TX FIFO full |
| 0x04   | RXDATA | RO   | [7:0]   | Received byte. A read pops one entry. |
|        |        |      | [31]    | RX FIFO empty (when set, [7:0] is not valid) |
| 0x08   | STATUS | RO / W1C | [0] | TX FIFO full |
|        |        |      | [1]     | TX idle: FIFO empty and shifter idle |
|        |        |      | [2]     | RX data valid |
|        |        |      | [3]     | RX overrun (W1C). A byte was received while the RX FIFO was full. |
| 0x0C   | CTRL   | RW   | [15:0]  | DIV: clk_aon cycles per bit, must be >= 2. Reset value 8. |
|        |        |      | [16]    | RX interrupt enable (irq while RX data is valid) |
|        |        |      | [17]    | TX-idle interrupt enable (irq while TX is idle) |

TXDATA, STATUS and CTRL honour byte strobes.

## Machine timer: `0x2000_1000`

`mtime` increments once per clk_aon cycle in every power state.

| Offset | Name        | Type | Reset        | Description |
|--------|-------------|------|--------------|-------------|
| 0x00   | MTIME_LO    | RW   | 0            | mtime[31:0] |
| 0x04   | MTIME_HI    | RW   | 0            | mtime[63:32] |
| 0x08   | MTIMECMP_LO | RW   | `0xFFFF_FFFF` | mtimecmp[31:0] |
| 0x0C   | MTIMECMP_HI | RW   | `0xFFFF_FFFF` | mtimecmp[63:32] |
| 0x10   | MSIP        | RW   | 0            | [0] machine software interrupt |

`mtip = (mtime >= mtimecmp)` is evaluated unsigned on 64 bits. To update
mtimecmp without a spurious interrupt, write `MTIMECMP_HI = 0xFFFF_FFFF`,
then `MTIMECMP_LO`, then `MTIMECMP_HI`.

## Interrupt controller: `0x2000_2000`

| Offset | Name    | Type | Reset | Description |
|--------|---------|------|-------|-------------|
| 0x00   | PENDING | RO   | -     | [7:0] raw source levels |
| 0x04   | ENABLE  | RW   | 0     | [7:0] per-source enable |
| 0x08   | ACTIVE  | RO   | -     | [7:0] `PENDING & ENABLE` (meip = OR of ACTIVE) |

The ENABLE write uses byte lane 0.

## PMU: `0x2000_3000`

| Offset | Name       | Type | Reset       | Description |
|--------|------------|------|-------------|-------------|
| 0x00   | CTRL       | RW   | `0x100`     | [1:0] MODE: 0 IDLE, 1 SLEEP, 2 DEEP_SLEEP (3 is treated as IDLE). [8] LP_EN: the PMU acts on WFI. |
| 0x04   | STATUS     | RO / W1C | -       | See below |
| 0x08   | DVFS       | RW   | 2           | [1:0] TARGET_OP (0..2; writes of 3 are ignored). Applied the next time the CPU is in IDLE. |
| 0x0C   | IRQ_EN     | RW   | 0           | [0] DVFS_DONE interrupt enable (intc source 2) |
| 0x10   | SCRATCH0   | RW   | 0           | Retained scratch. Boot ROM convention: pointer to the saved CPU context. |
| 0x14   | SCRATCH1   | RW   | 0           | Retained scratch. Boot ROM convention: resume magic `0x5E5E_0A0A`. |
| 0x18   | WAKE_CAUSE | RO   | 0           | [0] meip, [1] mtip, [2] msip (raw levels, unmasked), sampled when the last wake event was accepted |
| 0x1C   | SLEEP_CNT  | RO   | 0           | Number of completed power-off entries (SLEEP + DEEP_SLEEP) |
| 0x20   | VSEL       | RO   | 2           | [1:0] current regulator voltage select (`vsel_o`) |
| 0x24   | WAKE_MASK  | RW   | `0x7`       | [0] meip, [1] mtip, [2] msip: sources that are PMU wake events (see "Interrupt routing"). Reset: all three |
| 0x28   | IDLE_CNT   | RO   | 0           | Number of completed IDLE entries (clock gated with CTRL.MODE = IDLE, `CLK_GATE -> IDLE`). A refused power-down (ERR_DIRTY) is not counted |

STATUS fields:

| Bits  | Name        | Type | Description |
|-------|-------------|------|-------------|
| [4:0] | STATE       | RO   | PMU FSM state (see below) |
| [9:8] | CUR_OP      | RO   | Current DVFS operating point |
| [10]  | DVFS_PEND   | RO   | `TARGET_OP != CUR_OP` |
| [16]  | RESUME      | W1C  | CPU was powered up from SLEEP or DEEP_SLEEP |
| [17]  | RESUME_DEEP | W1C  | ... and the power-down was DEEP_SLEEP |
| [18]  | DVFS_DONE   | W1C  | A DVFS sequence completed |
| [19]  | ERR_DIRTY   | W1C  | A power-down was refused because the CPU did not report both `cache_clean` (no dirty D-cache line) and `idle_ack`; the CPU was kept in IDLE instead |
| [20]  | WDT_RST     | W1C  | The CPU was reset by a watchdog reset request (`dbg_wdt`, see "Watchdog reset"); set when the reset is released, together with clearing RESUME and RESUME_DEEP |

PMU FSM state encoding: 0 RUN, 1 IDLE_REQ, 2 CLK_GATE, 3 IDLE, 4 DVFS_VUP,
5 DVFS_SWITCH, 6 DVFS_VDN, 7 BUS_DRAIN, 8 ISO_ON, 9 PWR_OFF, 10 OFF,
11 RET_EXIT, 12 PWR_ON, 13 RST_CLK_ON, 14 RST_CLK_OFF, 15 RST_REL,
16 ISO_OFF, 17 CLK_UNGATE, 18 WAKE_REL, 19 WDT_GATE, 20 WDT_CHECK.

Operating points: OP0 is the slowest clock and lowest voltage, OP2 the fastest
and highest. OP2 is the reset point. The PMU raises `vsel` before it switches
to a faster clock, and lowers it after it switches to a slower one.

### Low-power entry (firmware view)

1. Set CTRL.MODE (and DVFS.TARGET_OP if a change is wanted).
2. Enable in `mie` every interrupt used as a wake source (MEIE for interrupt
   controller sources, MTIE, MSIE), and write the same set to WAKE_MASK
   (MEIE -> bit 0, MTIE -> bit 1, MSIE -> bit 2). WFI ends only on an
   interrupt that is pending and enabled in `mie` (`mstatus.MIE` may stay 0).
3. For SLEEP / DEEP_SLEEP, save the context to RAM, write SCRATCH0/1 and clean
   the D-cache (`mcachectl` bit 2), and check that `mcachectl` bit 31 (write-back
   error) reads 0. No cached store may follow the clean.
4. Execute `wfi`.

From IDLE, execution continues after `wfi`; IDLE_CNT has advanced by one if
the clock was gated. From SLEEP or DEEP_SLEEP, the CPU restarts at the boot ROM
with STATUS.RESUME set (doc/BOOT_ABI.md). A wake event already pending at
`wfi` returns immediately (no transition: IDLE_CNT and SLEEP_CNT unchanged).

### Watchdog reset

The watchdog (`dbg_wdt`, doc/DEBUG_SPEC.md section 8) requests a PD_CPU
reset with a 16-cycle pulse on `cpu_rst_req_o`, which is wired to the PMU
input `wdt_rst_req_i`. The PMU latches the rising edge and performs the
reset from whichever stable state it reaches first (requests in transient
states wait until the running sequence has reached RUN, IDLE or OFF):

| From | Sequence |
|---|---|
| RUN (CPU running, possibly hung) | WDT_GATE: gate `clk_cpu` (`idle_req` is raised too) and wait for the gate acknowledge; WDT_CHECK: wait for the frozen bus status to settle, then, if the AXI bridge reports no transaction in flight (`bus_idle`), ISO_ON. Otherwise the clock is ungated (CLK_UNGATE -> WAKE_REL -> RUN) and the reset is retried, so a transaction is never cut |
| IDLE (clock gated) | ISO_ON once the bridge is idle |
| OFF (SLEEP / DEEP_SLEEP) | the wake path (RET_EXIT for DEEP_SLEEP, PWR_ON ...) without waiting for a wake event |

then ISO_ON (isolation on, CPU reset asserted; `cache_clean` and `idle_ack`
are not required: the D-cache contents are discarded) -> PWR_ON ->
RST_CLK_ON -> RST_CLK_OFF -> RST_REL -> ISO_OFF -> CLK_UNGATE -> WAKE_REL ->
RUN, the same reset release as a wake from OFF, without switching the
domain off. At the reset release the PMU sets STATUS.WDT_RST and clears
STATUS.RESUME / RESUME_DEEP, so the boot ROM cold-boots (doc/BOOT_ABI.md).
SLEEP_CNT, IDLE_CNT and WAKE_CAUSE are not changed. Dirty D-cache lines are
lost; the RAM keeps every value that was written back. The application
image is not written at run time (its `.data` is copied out of the image by
the startup code), so the boot ROM's image check passes after the reset and
the application restarts.

## Wake timer: `0x2000_4000`

A down-counter on clk_aon.

| Offset | Name   | Type | Reset | Description |
|--------|--------|------|-------|-------------|
| 0x00   | CTRL   | RW   | 0     | [0] EN. Setting it while disabled reloads COUNT from LOAD. [1] PERIODIC: reload on expiry instead of disabling. |
| 0x04   | LOAD   | RW   | 0     | Start value. A write also loads COUNT. |
| 0x08   | COUNT  | RO   | 0     | Current value |
| 0x0C   | STATUS | W1C  | 0     | [0] EXPIRED (intc source 1) |

The timer expires (`EXPIRED = 1`) on the clk_aon cycle after COUNT reaches 0,
that is about LOAD + 1 cycles after it is enabled.
