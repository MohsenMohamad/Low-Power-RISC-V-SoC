# SoC Register Map

Source of truth: the RTL in `rtl/aon/`. The C definitions are in
`fw/include/soc.h`. All registers are 32 bits wide and sit in PD_AON
(clk_aon), so their contents survive SLEEP and DEEP_SLEEP. Unless noted,
registers take full-word writes only. A partial write (`wstrb != 0xF`) to a
register that requires full words, a write to a read-only register, or an
access to an unmapped offset returns SLVERR, and the register keeps its value.
An access to an unmapped address region returns DECERR.

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

ROM writes return SLVERR. RAM accesses while the RAM is in retention return
SLVERR. This cannot happen from the CPU, which is powered off whenever the RAM
is in retention.

## Interrupt routing

| CPU interrupt | Source                                     |
|---------------|--------------------------------------------|
| meip          | Interrupt controller output (`ACTIVE != 0`) |
| mtip          | Machine timer (`mtime >= mtimecmp`)        |
| msip          | Machine timer `MSIP[0]`                    |

The PMU wake event is `meip | mtip | msip`. Any interrupt that is enabled at
its source (and, for meip, in the interrupt controller) wakes the CPU from
IDLE, SLEEP and DEEP_SLEEP.

Interrupt controller source numbers:

| Bit | Source                                            |
|-----|---------------------------------------------------|
| 0   | UART (`aon_uart` irq)                             |
| 1   | Wake timer (`STATUS.EXPIRED`)                     |
| 2   | PMU (`STATUS.DVFS_DONE & IRQ_EN.DVFS_DONE`)       |
| 3   | External wake pin `ext_wake_i` (synchronized level) |
| 7:4 | Reserved, read as 0                               |

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
| 0x18   | WAKE_CAUSE | RO   | 0           | [0] meip, [1] mtip, [2] msip, sampled when the last wake event was accepted |
| 0x1C   | SLEEP_CNT  | RO   | 0           | Number of completed power-off entries (SLEEP + DEEP_SLEEP) |
| 0x20   | VSEL       | RO   | 2           | [1:0] current regulator voltage select (`vsel_o`) |

STATUS fields:

| Bits  | Name        | Type | Description |
|-------|-------------|------|-------------|
| [4:0] | STATE       | RO   | PMU FSM state (see below) |
| [9:8] | CUR_OP      | RO   | Current DVFS operating point |
| [10]  | DVFS_PEND   | RO   | `TARGET_OP != CUR_OP` |
| [16]  | RESUME      | W1C  | CPU was powered up from SLEEP or DEEP_SLEEP |
| [17]  | RESUME_DEEP | W1C  | ... and the power-down was DEEP_SLEEP |
| [18]  | DVFS_DONE   | W1C  | A DVFS sequence completed |
| [19]  | ERR_DIRTY   | W1C  | A power-down was refused because the D-cache reported dirty lines; the CPU was kept in IDLE instead |

PMU FSM state encoding: 0 RUN, 1 IDLE_REQ, 2 CLK_GATE, 3 IDLE, 4 DVFS_VUP,
5 DVFS_SWITCH, 6 DVFS_VDN, 7 BUS_DRAIN, 8 ISO_ON, 9 PWR_OFF, 10 OFF,
11 RET_EXIT, 12 PWR_ON, 13 RST_CLK_ON, 14 RST_CLK_OFF, 15 RST_REL,
16 ISO_OFF, 17 CLK_UNGATE, 18 WAKE_REL.

Operating points: OP0 is the slowest clock and lowest voltage, OP2 the fastest
and highest. OP2 is the reset point. The PMU raises `vsel` before it switches
to a faster clock, and lowers it after it switches to a slower one.

### Low-power entry (firmware view)

1. Set CTRL.MODE (and DVFS.TARGET_OP if a change is wanted).
2. For SLEEP / DEEP_SLEEP, save the context to RAM, write SCRATCH0/1 and clean
   the D-cache (in-house core).
3. Execute `wfi`.

From IDLE, execution continues after `wfi`. From SLEEP or DEEP_SLEEP, the CPU
restarts at the boot ROM with STATUS.RESUME set. A wake event already pending at
`wfi` returns immediately.

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
