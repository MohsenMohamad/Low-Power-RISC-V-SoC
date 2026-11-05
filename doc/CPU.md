# CPU subsystem (PD_CPU): core, I-cache, D-cache

Scope of this document: `rtl/core`, `rtl/cache`, `rtl/bus/axil_mux2.sv`, `rtl/cpu/cpu_top.sv`.

```
               cpu_top (PD_CPU, clk_cpu)
 ┌──────────────────────────────────────────────────────────────┐
 │  core_top  ──imem (req/gnt/rvalid)──▶ icache ──AXI-Lite──┐    │
 │   IF ID EX MEM WB                                          ├─▶ axil_mux2 ─▶ AXI4-Lite master
 │            ──dmem (req/gnt/rvalid)──▶ dcache ──AXI-Lite──┘    │
 │            ──maint (clean/flush/inval)──▶ caches              │
 └──────────────────────────────────────────────────────────────┘
```

## Core (`core_top`)

RV32IM + Zicsr + Zifencei + Zicntr, machine mode only, in-order, single issue.

| Stage | Function |
|---|---|
| IF | `core_fetch`: sequential fetch, 2-entry prefetch FIFO with fall-through (1 instruction/cycle on I$ hits); on redirect the FIFO is cleared and responses of in-flight requests are discarded |
| ID | decode (`core_decoder`), register read with WB write-through (`core_regfile`), CSR legality, hazard detection, interrupt hold |
| EX | ALU, branch/jump resolution (static not-taken prediction, redirect from EX), single-cycle 33×33 multiplier, 32-iteration restoring divider (`core_muldiv`), target-misalignment check |
| MEM | access-size alignment check, byte enables, data request issue |
| WB | load data alignment/extension, CSR read/write, trap entry, `mret`, `fence.i`, `wfi`, commit |

**Forwarding.** EX operands come from MEM (ALU/MUL/DIV results) or WB (all results, including load data and CSR read values arriving that cycle). While EX is held, the forwarded values are captured into the EX operand registers so a producer may leave WB. Loads and CSR reads produce their result only in WB, so a dependent instruction in ID is stalled while the producer is in EX (1-cycle load-use penalty).

**Branches.** Taken branches and all jumps redirect from EX (2-cycle penalty). A target with bit 1 set raises *instruction-address-misaligned* on the jump itself, with tval set to the target.

**Precise traps.** Exceptions are recorded in the stage that detects them (IF access fault, ID illegal/ecall/ebreak, EX misaligned target, MEM misaligned access, WB bus error) and are taken in WB. MEM issues a data request only when the WB instruction is certain to commit without a flush, so no younger store reaches the cache ahead of an older trap. A data bus error is reported as a load or store access fault, with tval set to the address. CSR writes, `mret`, `fence.i` and `wfi` flush the younger instructions and refetch.

**Interrupts.** `mip` samples `irq_{software,timer,external}_i` (synchronous to `clk`). When `mip & mie & mstatus.MIE` is non-zero, ID stops issuing. Once EX/MEM/WB have drained, the trap is taken with `mepc` set to the next instruction. Priority is MEI > MSI > MTI. `mtvec` supports direct and vectored modes (`base + 4*cause` for interrupts).

**WFI / IDLE.** `wfi` commits, then the core stops fetching and issuing until `(mip & mie) != 0`, regardless of `mstatus.MIE`, as the privileged spec allows. `core_sleep_o` is high when sleeping with the pipeline and fetch idle. The PMU uses it to gate `clk_cpu`, so wake-up detection must sit on the ungated side.

**Cache maintenance.** `fence.i` cleans the D-cache, invalidates the I-cache, then refetches. The custom M-mode CSR `mcachectl` (0x7C0) works as follows:

| bit | write 1 | read |
|---|---|---|
| 0 | D-cache flush (clean + invalidate) | 0 |
| 1 | I-cache invalidate | 0 |
| 2 | D-cache clean | 0 |
| 31 | – | sticky D-cache write-back error since the last maintenance operation |

The CSR write stalls in WB until the operations complete. Firmware uses `mcachectl` bit 2 (clean, or bit 0 flush) before power-down.

### CSRs

| CSR | Behaviour |
|---|---|
| mstatus | MIE, MPIE writable; MPP reads 11 (M-only); everything else 0 |
| mstatush | 0 |
| misa | 0x40001100 (RV32 I M), read-only (WARL) |
| mie / mip | MSI(3), MTI(7), MEI(11); mip is read-only |
| mtvec | bits[31:2] base, bit0 mode (direct/vectored), bit1 hardwired 0 |
| mscratch, mcause, mtval | full 32-bit |
| mepc | bits[1:0] read as 0 |
| mcycle(h), minstret(h) | 64-bit; a write to either half suppresses that cycle's increment |
| mcountinhibit | CY (bit 0), IR (bit 2) |
| cycle(h), instret(h), time(h) | read-only shadows; time comes from `mtime_i` (AON timer, synchronised by the SoC) |
| mhpmcounter3-31(h), mhpmevent3-31 | read 0, writes ignored |
| mvendorid, marchid, mimpid, mhartid, mconfigptr | 0 |
| mcachectl (0x7C0) | custom, see above |

Not implemented (illegal-instruction trap): PMP CSRs (no PMP), S/U-mode CSRs (`mcounteren`, `menvcfg`, …), debug/trigger CSRs, `hpmcounter*` (no Zihpm), F CSRs.

**`mtval` values.**

| Trap | mtval |
|---|---|
| Illegal instruction | instruction bits; for a 16-bit encoding (`bits[1:0] != 11`), only the low parcel, zero-extended |
| `ebreak` | pc |
| Misaligned/faulting access | address |
| Fetch fault | pc |
| Misaligned jump | target |
| `ecall` | 0 |

## Core memory interface

The same protocol is used for instruction and data ports:

- **Request:** `req`, `addr` (word aligned), `we`, `be`, `wdata`. Accepted when `req && gnt`. An un-granted request may be changed or withdrawn; the core does this on redirects and flushes.
- **Response:** exactly one `rvalid` (with `rdata`, `err`) per accepted request, in order, at the earliest one cycle after acceptance.
- **Ordering:** the core has at most one data request outstanding.

## Caches

Both caches have the same geometry:

| Parameter | Value |
|---|---|
| Capacity | 4 KB |
| Associativity | 2-way set-associative |
| Line size | 16 B |
| Sets | 128 |
| Address split | tag[31:11], index[10:4], word[3:2] |
| Replacement | 1-bit LRU per set; invalid ways are filled first |

Tags and data live in `tech_sram_sp` instances: single-port, 1-cycle synchronous read, output held when not enabled, bit write mask. Valid, dirty and LRU state are in flip-flops.

| | I-cache (`icache`) | D-cache (`dcache`) |
|---|---|---|
| Cacheable regions | boot ROM and RAM (parameters) | RAM (parameter) |
| Hit latency | 1 cycle, next request accepted in the same cycle | load: 1 cycle, pipelined like the I-cache; store hit: 1 cycle + 1 bubble (single-port data array) |
| Write policy | – (read-only) | write-back, write-allocate |
| Miss | refill 4 words, then re-lookup | evict dirty victim (4 single-beat writes), refill 4 words, then re-lookup |
| Uncached access | single AXI4-Lite read | single AXI4-Lite transaction with byte strobes |
| Bus error on refill | `err` response; line left invalid | `err` response (load/store access fault); line left invalid |
| Bus error on write-back | – | imprecise; sets `wb_err_o` (sticky until next maintenance start) |
| Maintenance | invalidate-all in 1 cycle (`inval_req`/`inval_done`) | clean, or flush (clean + invalidate): scans every set and way, writes back dirty lines |

AXI `AxPROT` is 001 for data and 101 for instruction (privileged, non-secure, data or instruction).

## AXI4-Lite mux (`axil_mux2`)

Arbitrates the two cache masters onto one AXI4-Lite master port. Read and write paths are arbitrated independently, round-robin. Each path carries one transaction at a time. The owner is locked from address phase to response, so address and data never change while VALID is high.

## Address map assumed by the cache parameters

| Region | Base | Size | Cacheable |
|---|---|---|---|
| Boot ROM | 0x0000_0000 | 16 KB | I |
| RAM (PD_AON, retained) | 0x8000_0000 | 128 KB | I + D |
| Peripherals | everything else | | no |

`cpu_top` parameters `ROM_*`/`RAM_*` set the cacheable windows. The co-simulation testbench uses a 4 KB-aligned 4 MB RAM window.

## Known limitations / deviations

- Single-cycle multiplier: the 33×33 product is combinational and is the likely critical path. The divider takes 33 cycles; division by zero and signed overflow take 1 cycle.
- No branch prediction beyond static not-taken. Load-use penalty is 1 cycle; CSR-read-use penalty is 1–2 cycles.
- `misa` is read-only. Spike's `misa` is writable (it can clear extensions); both are legal WARL behaviour.
- Without hardware misaligned-access support, misaligned loads and stores trap.
- D-cache write-back errors are imprecise: reported via `mcachectl[31]`, not as a trap.
