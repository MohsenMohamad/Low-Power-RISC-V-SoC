# Firmware

Bare-metal C firmware for the low-power SoC (`doc/SPEC.md`): boot ROM,
drivers, sleep/resume path, validation suite and UART bring-up monitor.

## Configurations

| PLATFORM | ARCH       | Target                                   | Run on                     |
|----------|------------|------------------------------------------|----------------------------|
| `lpsoc`  | `picorv32` | PicoRV32-based bring-up SoC              | Verilator RTL simulation   |
| `spike`  | `rv32m`    | Spike ISA simulator (RAM, CLINT, HTIF)   | Spike                      |
| `lpsoc`  | `rv32m`    | SoC with the in-house RV32IM core        | build only (core not in repo) |

`make -C fw PLATFORM=<p> ARCH=<a>` builds one configuration into
`build/fw/<p>-<a>/`; `make -C fw all-configs` builds all three.
`EXTRA_CFLAGS` is passed to the compiler (for example `-DSUITE_SELFTEST`,
`-DSTRESS_ITERS=100`, `-DAON_HZ=... -DREF_HZ=...`).

## Source layout

```
fw/include/        public headers (memory map, handoff, arch, drivers, pm, test, monitor)
fw/arch/rv32m/     CPU port: standard machine-mode CSRs
fw/arch/picorv32/  CPU port: PicoRV32 custom IRQ scheme mapped onto the same model
fw/platform/       per-platform console/exit/boot-argument code and linker scripts
fw/bootrom/        boot ROM (reset vector, cold/resume decision, image check)
fw/drivers/        UART, machine timer, interrupt controller, PMU, cache maintenance
fw/pm/             power management: context seal/validate, suspend, idle, DVFS
fw/app/            crt0, main, suite runner, UART monitor
fw/tests/          validation tests
tools/             mkimage.py, monitor_check.py, run_tests.py
```

## Memory map (lpsoc)

| Address       | Size   | Region                              | Domain |
|---------------|--------|-------------------------------------|--------|
| `0x0000_0000` | 16 KB  | boot ROM (reset vector `0x0`)       | AON    |
| `0x2000_0000` | 128 KB | RAM, cacheable                      | AON (retention) |
| `0x3000_0000` | 128 KB | same RAM, uncached alias            | AON    |
| `0x4000_0000` |        | UART                                | AON    |
| `0x4000_1000` |        | interrupt controller                | AON    |
| `0x4000_2000` |        | PMU                                 | AON    |
| `0x4001_0000` |        | machine timer, CLINT register layout | AON   |
| `0x4F00_0000` |        | external port (testbench control)   | AON    |
| `0x5000_0000` |        | cache control                       | CPU    |

Register definitions: `fw/include/soc.h`. The timer uses the CLINT layout
(`msip` +0x0, `mtimecmp` +0x4000, `mtime` +0xBFF8), so the same driver runs
on Spike's CLINT.

### RAM layout

| Offset   | Content                                                        |
|----------|----------------------------------------------------------------|
| `0x000`  | `handoff_t`: soft trap vector, boot status, reset cause, counters, saved context |
| `0x200`  | persistent area, accessed only through the uncached alias (suite runner state) |
| `0x400`  | boot ROM `.data`/`.bss`, ROM stack up to `0x1000`             |
| `0x1000` | application image (`image_hdr_t` first), then `.bss`; stack at top of RAM |

## Boot ROM

`fw/bootrom/rom_main.c`

1. Install the ROM trap handler, then invalidate both caches and enable
   them (`cache_init`). After PD_CPU power-up the cache tag arrays hold
   garbage, so INV_ALL must come before any CLEAN/FLUSH.
2. Read `PMU.RST_CAUSE`:
   - `SLEEP` / `DEEP`: if the saved context is valid (`magic == "CTX1"`
     and CRC-32 over the register area matches), set `boot_status =
     RESUMED`, increment `resumes` and call `pm_ctx_restore()`. This
     never returns: execution continues inside the application's
     `pm_suspend()`. An invalid context falls through to a cold boot with
     `boot_status = RESUME_BADCTX`.
   - `POR`: clear `handoff_t` and the persistent area. RAM contents are
     undefined after power-on.
   - `SWRST`: keep RAM.
3. Cold boot: invalidate the context, then check the image header at
   `0x2000_1000` (magic, load address, size, entry, CRC-32 of the image).
   If valid, clean D$, invalidate I$ and jump to the entry point.
   Otherwise set `boot_status = NO_IMAGE` and start the UART monitor
   (peek/poke/regs/go/reset).

On PicoRV32 the fixed IRQ vector at `0x10` is a 4-instruction stub in ROM.
It saves `t0` in `q2` and jumps through `handoff.soft_mtvec`, which plays the
role of `mtvec`.

Image header (`tools/mkimage.py` patches the CRC after linking):

```
magic "LPAP" | version | load_addr | size | entry | crc32(bytes after header) | 0 | 0
```

## Sleep / resume path

`fw/pm/pm.c`, `fw/arch/*/ctx.S`, `fw/arch/*/pm_asm.S`

```
pm_suspend(SLEEP|DEEP_SLEEP)
  require PMU.WAKE_EN != 0                  (otherwise PM_EINVAL)
  disable interrupts
  pm_ctx_save(&handoff.ctx)                 ra sp gp tp s0-s11 + CPU state
  pm_ctx_seal: CRC-32, magic
  pm_flush_and_wfi:   D$ FLUSH_ALL  ->  PMU.CTRL = mode  ->  WFI
        (no stack or cacheable stores after the flush)
  PMU: clock gate -> isolation -> reset -> switch off [-> RAM retention]
  ... wake source fires ...
  PMU: [retention exit] -> switch on -> power_good -> reset release
       -> isolation off -> clock on
  boot ROM: RST_CAUSE = SLEEP/DEEP, context valid -> pm_ctx_restore
pm_ctx_save returns 1 -> invalidate context -> restore interrupts -> PM_RESUMED
```

If WFI returns without a power-down, the PMU refused it because a wake
event was already pending. `pm_suspend` then invalidates the context, sets
the PMU mode back to IDLE and returns `PM_ABORTED`.

CPU state saved besides the callee-saved registers:

| ARCH       | `arch[]`                                    |
|------------|---------------------------------------------|
| `rv32m`    | `mstatus`, `mie`, `mtvec`, `mscratch`       |
| `picorv32` | IRQ mask (`maskirq`), soft `mtvec`          |

Caller-saved registers do not need saving: `pm_suspend` is an ordinary
function call (setjmp/longjmp semantics, `returns_twice`).

**Wake latency budget.** The wake timer must cover suspend entry: context
save and CRC, the D$ flush and any I$ misses over the CDC bridge. On the
PicoRV32 platform at OP0 this measured about 3400 mtime ticks (~105 us at
clk_aon = 32.3 MHz), and it scales with the CPU clock at lower operating
points. Cleaning the D$ before arming the timer keeps the in-suspend flush
short. A timer that expires early makes the PMU abort the sleep, which is
correct behaviour, not a hang.

`pm_idle()`: PMU mode IDLE + WFI; the PMU gates clk_cpu until any
interrupt line is pending.

`pm_set_opp(op)`: op 0 = clk_ref, 1 = clk_ref/2, 2 = clk_ref/4. The
function enables the PMU `DVFS_DONE` event (PMU -> intc source 1 -> MEIP),
writes `DVFS_OP` and `CTRL.DVFS_REQ`, then executes WFI. The PMU switches
voltage and clock only while clk_cpu is gated, raising the voltage before
increasing the frequency and lowering it after decreasing. Requires that
no other interrupt line is pending (the PMU never gates while one is);
otherwise it gives up after 64 wakes and returns -2.

## Drivers

`fw/include/drivers.h`

- **UART:** polled TX/RX, `uart_flush` (wait until shifter idle), divisor, IE.
- **Timer:** glitch-free 64-bit `mtimecmp` update (high word written to
  all-ones first), `timer_cancel`, `msip`, busy delay.
- **Interrupt controller:** enable mask, software-set/clear, pending, claim
  (lowest pending enabled source).
- **PMU:** mode/DVFS request, wake sources, reset cause, counters, software
  reset (flushes D$ first).
- **Cache:** `cache_init` (INV_ALL + enable), all/range clean, invalidate
  and flush for D$, invalidate for I$, `cache_sync_icache` (clean D$ +
  invalidate I$ after writing code), statistics. Commands block until
  complete.

## CPU ports

`fw/include/arch.h` gives one trap model (mcause codes, `epc`, `tval`)
and one interrupt-enable model (global `MIE` + per-source `mie`).

- **`rv32m`:** direct-mode `mtvec`, `mret`, standard CSRs.
- **`picorv32`:** `pico_trap()` translates the IRQ bitmask in `q1`:
  - bit 1 → decode the instruction at `q0-4` to `ecall` (11), `ebreak` (3)
    or illegal (2, `tval` = instruction);
  - bit 2 → misaligned load/store (4/6, `tval` computed from `rs1+imm`);
  - bits 3/4/5 → MTI/MSI/MEI.

  `maskirq` emulates `MIE`/`mie`; the exception lines are never masked
  (a masked exception halts PicoRV32). WFI is `waitirq`.

  Not available on PicoRV32, and therefore skipped there: the M-mode CSR
  file and access-fault exceptions.

## Validation suite

Every test is self-checking and returns PASS or the failing source line.
The runner prints one line per test and a final signature:

```
[TEST  42] pm_sleep_resume              PASS
SUITE DONE pass=37 fail=0 skip=1 signature=0x600d0025
SUITE RESULT: PASS
```

Signature: `0x600Dnnnn` = all passed (`nnnn` passed tests),
`0xBAD0nnnn` = `nnnn` failures. It is written to
`handoff.signature`, to the testbench EXIT register (simulation exit
status), or to HTIF (Spike exit status, 0/1). A test whose required
capabilities are missing is reported as SKIP, never as PASS. After every
test the runner restores a baseline: interrupts off, timer cancelled, intc
cleared, PMU idle, OP0, caches enabled.

Tests that reset the CPU (45, 46) store the runner state in the persistent
area. After the reboot the application completes the test in its
`after_reboot()` function and the run continues.

| ID | Name | Checks | Requires |
|----|------|--------|----------|
| 1  | csr_counters | cycle/instret counters, exact instret delta of a known loop | counters |
| 2  | csr_machine_regs | mscratch patterns, csrrw/s/c and immediate forms return old value, misa (MXL, I, M), mhartid, mstatus.MIE, MPP legality, mie, mtvec, minstret write | mcsr |
| 3  | csr_mip_pending | mip.MTIP / mip.MSIP follow the CLINT | mcsr, clint |
| 10 | exc_ecall | cause 11, epc | |
| 11 | exc_ebreak | cause 3, epc | |
| 12 | exc_illegal_insn | cause 2, epc, tval for two encodings | |
| 13 | exc_misaligned | lw/lh/sw: cause 4/6, epc, tval | misalign |
| 14 | exc_access_fault | load/store to unmapped address: cause 5/7, tval | accfault |
| 15 | exc_regs_preserved | x1, x5..x31 preserved across a trap (assembly) | |
| 16 | exc_back_to_back | 100 consecutive traps | |
| 20 | irq_timer | MTI taken once, after mtimecmp | clint |
| 21 | irq_timer_masking | pending-but-masked not taken; taken on enable; per-source disable | clint |
| 22 | irq_software | MSI via msip | clint |
| 23 | irq_external_intc | MEI via intc software source, claim id | intc |
| 24 | irq_intc_priority_mask | claim order, disabled source stays pending | intc |
| 25 | irq_wfi_wake_masked | WFI wakes on a masked pending IRQ without taking it; one WFI covers the wait; PMU IDLE count | clint |
| 26 | irq_during_mem_traffic | periodic MTI during memory traffic | clint |
| 30 | cache_writeback_clean | write-back: RAM unchanged until clean; one write-back per line; clean keeps lines valid | cache |
| 31 | cache_invalidate_flush_line | stale copy until invalidate; invalidate discards dirty data; flush = clean + invalidate | cache |
| 32 | cache_eviction_lru | 2x capacity writes: evictions write back; LRU replacement in a set | cache |
| 33 | cache_random_vs_model | 6000 random byte/half/word accesses and maintenance ops checked against an uncached reference copy; RAM equals the model after flush | cache |
| 34 | cache_icache_coherence | self-modifying code: I$ invalidate and D$ clean are both required | cache |
| 35 | cache_disable_bypass | disable flushes; bypass goes straight to RAM | cache |
| 40 | pm_ctx_save_restore | s0..s11 restored; CRC detects corruption; invalid magic rejected | |
| 41 | pm_idle_clock_gated | wake at mtimecmp; clk_cpu cycles during IDLE < 1/4 of running | pmu, clint |
| 42 | pm_sleep_resume | SLEEP: PM_RESUMED, reset cause, ROM boot status, resume count, PMU counters, off time, wake source, cycle counter restarted (PD_CPU reset), RAM CRC, caches on, CSR/IRQ-enable state, trap vector | pmu, bootrom, clint |
| 43 | pm_deep_sleep_resume | same for DEEP_SLEEP (RAM in retention) | pmu, bootrom, clint |
| 44 | pm_sleep_abort | pending wake event → PM_ABORTED, mode reset; no wake source → EINVAL; PMU-level abort counted and flagged | pmu, clint |
| 45 | pm_sw_reset_cold_boot | software reset → ROM cold path, reset cause SWRST | pmu, bootrom |
| 46 | pm_sleep_without_flush | sleep without D$ flush → context never reached RAM → ROM rejects it, cold boot with RESUME_BADCTX | pmu, bootrom, cache |
| 50 | dvfs_switch_sequence | OP sequence 1,2,0,2,1,0: CUR_OP, VSEL, counter; invalid OP rejected | dvfs |
| 51 | dvfs_frequency_measured | clk_cpu/mtime ratio at each OP within ±2 % of expected | dvfs, counters |
| 52 | dvfs_only_while_idle | a DVFS request without WFI does not change the clock | dvfs |
| 60 | stress_sleep_wake_dvfs | 24 random IDLE/SLEEP/DEEP iterations with OP changes and RAM modifications; data CRC after each wake; PMU and ROM counters match | pmu, dvfs, bootrom, clint |
| 61 | pm_state_opp_coverage | every power state at every OP, all six OP→OP transitions, OP retained across power-down; coverage matrix printed | pmu, dvfs, bootrom, clint |
| 70 | drv_uart | status bits, divisor, IE, TX-idle IRQ at intc | uart, intc |
| 71 | drv_timer | mtime progress, 64-bit mtimecmp, cancel, prescaler | clint |
| 72 | drv_intc | enable, soft set/clear, RAW vs PENDING, claim | intc |
| 73 | drv_pmu_regs | ID, reset cause, WAKE_EN, EVENT_IE, CTRL idle, power good | pmu |
| 74 | boot_rom_handoff | ROM version, boot status, image header and CRC, soft mtvec | bootrom |
| 98/99 | selftest_* | only with `-DSUITE_SELFTEST`: one must SKIP, one must FAIL | |

## UART monitor

Built into the application (boot argument "monitor", or any board without
the testbench device) and, reduced, into the boot ROM (no valid image).

```
help                       list commands
peek <addr|reg> [n]        read n words           -> "0x40002010: 0x00000001"
poke <addr|reg> <value>    write a word           -> "OK" (cacheable RAM: line cleaned)
regs <block>               dump uart|intc|pmu|timer|cache|handoff
go <addr>                  clean D$, invalidate I$, jump
reset                      PMU software reset of PD_CPU
list                       list tests (with unsupported capabilities)      [app]
run <id|all>               run test(s)                                     [app]
info                       boot status, reset cause, counters, OP          [app]
sleep <idle|sleep|deep> <ticks|uart>
                           enter a power state; wake by timer or UART RX   [app]
opp <0..2>                 change operating point                          [app]
exit [code]                end simulation                                  [app]
```

Registers can be named symbolically as `<block>.<reg>`, e.g.
`pmu.rst_cause` or `cache.dc_miss`. Accesses that trap are reported as
`ERR fault` instead of crashing the monitor. The prompt is `mon> `.
`sleep ... uart` prints `zzz> ` and sleeps until a byte arrives.

## Running

```bash
make test
```

`make test` runs `tools/run_tests.py`. Logs are written to `build/test/`,
the summary to `build/test/summary.txt`. A step whose tool is missing is
reported as SKIPPED, never as PASS.

Single runs:

```bash
build/picorv32/obj/Vtb_top +rom_hex=build/fw/lpsoc-picorv32/rom.hex +ram_hex=build/fw/lpsoc-picorv32/app.hex +test=42
```

```bash
spike --priv=M --isa=rv32im_zicsr_zifencei -m0x80000000:0x100000 build/fw/spike-rv32m/app.elf
```

Monitor sessions are text specs (`platform/picorv32/tests/monitor_*.txt`):
`>` lines are sent, `<` lines are regexes that must match the response,
and `!` lines must not match.
`tools/monitor_check.py gen` produces the UART input and
`tools/monitor_check.py check` verifies the captured UART log.

## Limitations

- The `lpsoc`/`rv32m` configuration (in-house core) is only compiled: the
  core is not in this repository, so its boot ROM, resume path and suite
  have not been executed.
- On the PicoRV32 platform the CSR tests (2, 3) and the access-fault test
  (14) cannot run; they run on Spike. Spike has no SoC peripherals, so
  cache, PMU, DVFS, intc and UART tests run only on the PicoRV32 SoC.
- Spike's `mtime` advances with retired instructions, not wall time; the
  timer tests only rely on ordering.
- The UART divisor stays at its reset value (`UART_DIV` SoC parameter);
  the testbench decoder assumes the same value.
