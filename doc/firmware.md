# Firmware

Bare-metal C firmware for the low-power SoC (doc/SPEC.md "Firmware"): boot
ROM, drivers, power management, validation suite and UART bring-up monitor.
One source tree, `fw/`, for two platforms. Register maps: doc/SOC_REGMAP.md
(normative, transcribed in `fw/include/soc.h`). Boot and resume:
doc/BOOT_ABI.md (normative, `fw/include/handoff.h`).

## Platforms

| PLATFORM | Target | Runs on | Outputs (`build/fw/<platform>/`) |
|---|---|---|---|
| `lpsoc` | the SoC with the in-house RV32IM core | `sim/tb_soc.sv` (Verilator, Icarus) | `rom.hex` (boot ROM), `<app>.hex` / `<app>.img` / `<app>.elf` for `suite`, `pm_test`, `boot_test`, `neg_fail` |
| `spike` | Spike ISA simulator (RAM at `0x8000_0000`, CLINT, HTIF) | Spike | `suite.elf` |

`make -C fw [PLATFORM=lpsoc|spike]`, `make -C fw all-platforms` (also
`make fw` at the top level). Compiler: GCC 13.2 / binutils 2.42,
`-march=rv32im_zicsr_zifencei -mabi=ilp32`; the build fails on any compressed
instruction. `EXTRA_CFLAGS` is passed to the compiler (for example
`-DSUITE_SELFTEST`, `-DSTRESS_ITERS=100`).

## Source layout

```
fw/include/        soc.h (register map), handoff.h (boot ABI), drivers.h, pm.h,
                   arch.h, trap.h, test.h, lib.h, monitor.h, platform_api.h
fw/arch/rv32m/     CPU port: machine-mode CSRs, trap entry, context save/restore,
                   power-down tail (pm_asm.S)
fw/platform/       lpsoc/ and spike/: console, boot argument, exit, linker scripts
fw/bootrom/        boot ROM: reset vector, resume check, image check, ROM monitor
fw/drivers/        uart, timer (machine timer), wtimer (wake timer), intc, pmu,
                   cache (CSR mcachectl)
fw/pm/             power management: IDLE, SLEEP, DEEP_SLEEP, DVFS
fw/lib/            printf, string, CRC-32, trap dispatch
fw/app/            crt0.S (image header + startup), main.c + suite.c (validation
                   suite + monitor), monitor.c, pm_test.c, boot_test.c, neg_fail.c
fw/tests/          validation tests (t_*.c, regs_asm.S), monitor/ session specs
tools/             mkimage.py, monitor_check.py, fw_results.py
```

There is one copy of every driver and one startup per program kind: the boot
ROM (`bootrom/start.S`) and the application startup (`app/crt0.S`), shared by
all four applications.

## Drivers (`fw/include/drivers.h`)

- **UART** (`0x2000_0000`): polled TX/RX through TXDATA / RXDATA, STATUS,
  CTRL = divider + RX / TX-idle interrupt enables.
- **Machine timer** (`0x2000_1000`): 64-bit `mtime`, glitch-free `mtimecmp`
  update (high word to all-ones first), `msip`. The Spike port uses the same
  driver with the CLINT offsets from `platform/spike/platform.h`.
- **Wake timer** (`0x2000_4000`): one-shot / periodic down-counter, intc source 1.
- **Interrupt controller** (`0x2000_2000`): PENDING / ENABLE / ACTIVE. Sources are
  level-sensitive and cleared at their origin; `intc_claim()` returns the lowest
  active source (there is no claim register).
- **PMU** (`0x2000_3000`): register access (mode, status, DVFS target, scratch,
  wake cause, counters, wake mask); sequences are in `fw/pm/pm.c`.
- **Caches**: only through CSR `mcachectl` (0x7C0): `dcache_clean`,
  `dcache_flush` (clean + invalidate), `icache_invalidate`, `cache_sync_icache`.
  Clean and flush return -1 when `mcachectl` bit 31 (write-back error) is set;
  they are declared `warn_unused_result`, so with `-Werror` every caller must
  check it.

Every driver uses full-word register accesses; partial writes, writes to
read-only registers and unmapped offsets return SLVERR, which the core takes
as a precise load / store access fault (test 76).

## Power management (`fw/include/pm.h`)

| Call | Result |
|---|---|
| `pm_idle()` | `PM_WOKE` only if the PMU completed an IDLE entry (`IDLE_CNT` advanced), otherwise `PM_ABORTED` |
| `pm_suspend(PM_SLEEP / PM_DEEP_SLEEP, flags)` | `PM_RESUMED` after power-off and ROM resume; `PM_ABORTED` if the CPU was not powered down; `PM_EWB` on a D-cache write-back error; `PM_EINVAL` without a wake source in `mie` |
| `pm_set_opp(op)` | 0 when `CUR_OP` = `op` (the PMU switches in IDLE; DVFS_DONE interrupt ends the WFI); immediate 0 for the current point |
| `pm_wfi()` | WFI after programming the PMU wake mask from `mie` |

Wake sources are the interrupts enabled in `mie`; `pm_wfi` copies them into
`PMU.WAKE_MASK` (meip / mtip / msip), so the PMU wakes the CPU only for
sources the firmware enabled (doc/SOC_REGMAP.md). The SLEEP sequence and the
resume path are specified in doc/BOOT_ABI.md. Operating points: OP0 slowest,
OP2 fastest (reset).

## Validation suite

Every test is self-checking and returns PASS or the failing source line.
Tests whose capabilities a platform lacks are reported as SKIP. The runner
prints one line per test and a final summary:

```
[TEST  42] pm_sleep_resume              PASS
SUITE DONE pass=45 fail=0 skip=0 signature=0x600d002d
SUITE RESULT: PASS
PASS
```

Signature `0x600Dnnnn` = all passed (`nnnn` passed), `0xBAD0nnnn` = `nnnn`
failures; the last line is the platform exit (`PASS` / `FAIL 0x<code>`).
The host-side result checker is the stage-1 checker
(`scripts/check_results.py`) fed by `tools/fw_results.py`, against the
required-test lists `dv/regress/fw_suite_lpsoc.required` and
`dv/regress/fw_suite_spike.required` (a missing, unknown, skipped or failed
test, or a FAIL followed by a PASS for the same test, fails the run).

After every test the runner restores a baseline: interrupts off, timers
stopped, intc disabled, PMU in IDLE mode at OP2, wake mask reset. Test 45
reboots the CPU; the runner keeps its state in the persistent area and
finishes the test in its `after_reboot()` function.

| ID | Name | Checks | Requires |
|---|---|---|---|
| 1 | csr_counters | cycle / instret counters, exact instret delta of a known loop | counters |
| 2 | csr_machine_regs | mscratch patterns, csrrw/s/c and immediate forms, misa, mhartid, mstatus.MIE, MPP, mie, mtvec, minstret write | mcsr |
| 3 | csr_mip_pending | mip.MTIP / mip.MSIP follow the machine timer | mcsr, mtimer |
| 10-16 | exc_* | ecall, ebreak, illegal (tval), misaligned (tval), access fault (load / store, tval), registers preserved across a trap, 100 back-to-back traps | |
| 20-22 | irq_timer, irq_timer_masking, irq_software | MTI taken once after mtimecmp, masking by mstatus / mie, MSI | mtimer |
| 23 | irq_external_intc | MEI from the wake timer through the intc, claim, cleared at the origin | intc, wtimer |
| 24 | irq_intc_priority_mask | two sources (UART TX-idle, wake timer): lowest first; a disabled source stays pending | intc, uart, wtimer |
| 25 | irq_wfi_wake_masked | WFI with the source enabled but `mstatus.MIE` = 0 resumes without a trap; one WFI covers the wait; exactly one IDLE entry | mtimer |
| 26 | irq_during_mem_traffic | periodic MTI during memory traffic | mtimer |
| 30 | cache_writeback_clean | write-back: RAM unchanged until clean; clean keeps lines valid; a flush does not write back clean lines | cache |
| 31 | cache_flush_invalidate | stale copy until flush; flush writes dirty data back and invalidates | cache |
| 32 | cache_eviction_lru | 2x capacity writes: evictions write back; LRU victim in a set (observed through the alias) | cache |
| 33 | cache_random_vs_model | 6000 random byte / half / word accesses and clean / flush operations against an uncached reference copy | cache |
| 34 | cache_icache_coherence | self-modifying code: I-invalidate and D-clean are both required; `fence.i` does both | cache |
| 35 | cache_uncached_alias | `0x3000_0000` = same RAM, bypasses dirty lines, byte / halfword strobes | cache |
| 36 | cache_mcachectl_csr | bit 31 reads 0 after a clean; I-invalidate does not clean D | cache |
| 40 | pm_ctx_save_restore | s0..s11 restored; CRC detects corruption of regs and arch words; magic; CRC check value | |
| 41 | pm_idle_clock_gated | IDLE entry completed, wake at mtimecmp, clk_cpu cycles during IDLE < 1/4 of running | pmu, mtimer |
| 42, 43 | pm_sleep_resume, pm_deep_sleep_resume | PM_RESUMED, ROM handoff (status, cause, reason, counters), SLEEP_CNT, wake cause, consumed resume state, cycle counter restarted, RAM CRC, CSRs, trap vector | pmu, bootrom, mtimer |
| 44 | pm_sleep_abort | wake event pending -> ABORTED, no power-off, PMU back to IDLE mode; no wake source -> EINVAL | pmu, mtimer |
| 45 | pm_resume_bad_crc_cold_boot | context with a wrong CRC: power-off happens, the ROM rejects the context (reason CRC) and cold-boots; checked after the reboot | pmu, bootrom, mtimer |
| 46 | pm_sleep_dirty_refused | SLEEP without the D-cache clean: PMU refuses (ERR_DIRTY), ABORTED, no power-off, dirty data intact | pmu, cache, mtimer |
| 47 | pm_sleep_wake_timer | SLEEP and DEEP_SLEEP woken by the wake timer through the intc (MEIP) | pmu, bootrom, wtimer, intc |
| 48 | pm_wake_mask | a pending interrupt not enabled in `mie` does not wake the PMU: exactly one IDLE entry, clock stays gated (stage-1 open item 3) | pmu, mtimer, wtimer, intc |
| 50 | dvfs_switch_sequence | all six OP pairs: CUR_OP, VSEL, no pending; same OP; OP 3 rejected | dvfs |
| 51 | dvfs_frequency_measured | clk_cpu / mtime ratio at each OP within +-2 % of the testbench clocks | dvfs, counters |
| 52 | dvfs_only_while_idle | a DVFS target without WFI stays pending | dvfs |
| 60 | stress_sleep_wake_dvfs | 24 random IDLE / SLEEP / DEEP iterations with OP changes and RAM modifications; data CRC after each wake; counters | pmu, dvfs, bootrom, mtimer |
| 61 | pm_state_opp_coverage | every power state at every OP, all six OP transitions, OP retained across power-down; matrix printed | pmu, dvfs, bootrom, mtimer |
| 70 | drv_uart | status bits, divider, interrupt enables, TX-idle request at the intc | uart, intc |
| 71 | drv_timer | mtime progress (1 tick per clk_aon), 64-bit mtimecmp, cancel, msip | mtimer |
| 72 | drv_intc | enable, pending vs active, claim, byte-lane write | intc, wtimer |
| 73 | drv_pmu_regs | reset values, IRQ_EN, scratch, MODE 3 and OP 3 handling, wake mask, IDLE_CNT | pmu |
| 74 | boot_rom_handoff | ROM version, boot status, image header fields and CRC, resume state consumed | bootrom |
| 75 | drv_wake_timer | count down, one-shot, periodic reload, W1C | wtimer, mtimer |
| 76 | bus_errors_access_rules | SLVERR -> precise access fault for unmapped regions / offsets, writes to RO registers, partial writes; the register keeps its value | pmu, intc, uart, wtimer |
| 98, 99 | selftest_* | only with `-DSUITE_SELFTEST`: one must SKIP, one must FAIL | |

On Spike the tests that need SoC peripherals are skipped (27 tests); the
required list for Spike names exactly the tests that must run.

## UART monitor

Built into the validation application (no host boot argument) and, reduced,
into the boot ROM (no valid image).

```
help                       list commands
peek <addr|reg> [n]        read n words           -> "0x20003004: 0x00000100"
poke <addr|reg> <value>    write a word           -> "OK" (cacheable RAM: D-cache cleaned)
regs <block>               dump uart|intc|pmu|timer|wtimer|handoff
go <addr>                  clean D$, invalidate I$, jump
list                       list tests (with unsupported capabilities)      [app]
run <id|all>               run test(s)                                     [app]
info                       boot status, reset cause, counters, OP          [app]
sleep <idle|sleep|deep> <ticks|uart>
                           enter a power state; wake by timer or UART RX;
                           "ERR transition ABORTED" if it did not complete [app]
opp <0..2>                 change operating point                          [app]
exit [code]                end the run (PASS / FAIL)                        [app]
```

Registers can be named `<block>.<reg>`, e.g. `pmu.status`. Accesses that
fault are reported as `ERR fault <addr>`. The prompt is `mon> `; `sleep ... uart`
prints `zzz> ` and sleeps until a byte arrives.

Monitor sessions are text specs (`fw/tests/monitor/monitor_*.txt`): `>` lines
are sent, `<` lines are regexes that must match the response, `!` lines must
not match. `tools/monitor_check.py gen` produces the UART input and
`tools/monitor_check.py check` verifies the captured UART log.

## Running

`make test` runs everything (doc/VERIFICATION.md). Firmware steps alone:

```bash
make fw-suite fw-spike fw-monitor fw-neg
```

A single run on the SoC (Verilator):

```bash
build/sim/vl/Vtb_soc +rom=build/fw/lpsoc/rom.hex +ram=build/fw/lpsoc/suite.hex +bootarg=8000002a +cov=build/sim/cov_one.txt
```

On Spike:

```bash
spike --priv=M --isa=rv32im_zicsr_zifencei -m0x80000000:0x100000 build/fw/spike/suite.elf
```
