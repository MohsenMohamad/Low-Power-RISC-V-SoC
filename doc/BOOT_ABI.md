# Boot and resume ABI

Normative for the boot ROM, the applications and the host tools (doc/SPEC.md
"Boot and resume ABI"). Implemented by `fw/bootrom/` (boot ROM),
`fw/pm/pm.c` and `fw/arch/rv32m/{ctx,pm_asm}.S` (context save, power-down),
`fw/app/crt0.S` (image header), `tools/mkimage.py` (image builder) and
`sim/tb_soc.sv` (host side in simulation). The C definitions are in
`fw/include/handoff.h`; the register maps are in doc/SOC_REGMAP.md.

This is the only boot/resume ABI. It replaces the interim stage-1 ABI of
`fw/crt0.S` (context pointer in SCRATCH0, magic in SCRATCH1, 20-word context
with the CRC in word 20) and the firmware branch's ABI (PMU reset-cause
register, context validity only); see "Reconciliation" below.

## Memory layout

`RAM_BASE` = `0x1000_0000` (128 KB, PD_AON, retained in SLEEP and in retention
mode in DEEP_SLEEP). Uncached alias: `RAM_BASE + 0x2000_0000` = `0x3000_0000`.

| Offset (from RAM_BASE) | Size | Content | Written by | Cleared by the ROM |
|---|---|---|---|---|
| `0x000` | 64 B | handoff block (below) | ROM, application | at power-on |
| `0x040` | 104 B | saved CPU context `pm_ctx_t` (`CTX_ADDR` = `0x1000_0040`) | application (`pm_suspend`) | magic word at every boot |
| `0x100` | 8 B | host mailbox: `HARG` magic, boot argument | host / testbench | never |
| `0x200` | 512 B | persistent area: kept across a resume, a resume-rejected cold boot and a watchdog reset; accessed only through the uncached alias | application | at power-on |
| `0x400` | 3 KB | boot ROM `.data`, `.bss` and stack (stack top `RAM_BASE + 0x1000`) | ROM | - |
| `0x1000` | up to 124 KB | application image (header first; never written at run time), then the run-time copy of its `.data`, its `.bss`; application stack at the top of RAM | host (image), application | - |

The boot ROM touches only `0x000`-`0x0FF` (handoff and context),
`0x200`-`0x3FF` (clear at power-on) and its own `0x400`-`0xFFF`, so a resume
never changes application memory.

### Handoff block (`handoff_t`, `RAM_BASE + 0x000`)

| Offset | Field | Meaning |
|---|---|---|
| `0x00` | `rom_version` | `0x0002_0000` (2.0) |
| `0x04` | `boot_status` | 1 COLD (power-on, image started), 2 RESUMED, 3 RESUME_BADCTX (woke from SLEEP / DEEP_SLEEP, context rejected, cold boot), 4 NO_IMAGE (ROM monitor) |
| `0x08` | `rst_cause` | 1 POR (`STATUS.RESUME` = 0), 2 SLEEP (`RESUME` = 1, `RESUME_DEEP` = 0), 3 DEEP (`RESUME_DEEP` = 1), 4 WDT (`STATUS.WDT_RST` = 1: PD_CPU reset by the watchdog, doc/SOC_REGMAP.md "Watchdog reset") |
| `0x0C` | `boot_reason` | first resume check that failed: 0 none (resumed), 1 no resume flag, 2 SCRATCH1 magic, 3 SCRATCH0 pointer, 4 context magic, 5 context CRC |
| `0x10` | `pmu_status` | `PMU.STATUS` read at ROM entry |
| `0x14` | `cold_boots` | cold boots since power-on (including resume-rejected ones) |
| `0x18` | `resumes` | successful resumes since power-on |
| `0x1C` | `bad_resumes` | rejected resumes since power-on |
| `0x20` | `signature` | last run's exit code (validation suite signature, 0 = pass) |
| `0x24`-`0x3F` | reserved | 0 |

## Saved context (`pm_ctx_t`, `CTX_ADDR` = `RAM_BASE + 0x040`)

| Offset | Words | Content |
|---|---|---|
| `0x00` | 1 | magic `0x3158_5443` ("CTX1") when valid |
| `0x04` | 1 | CRC-32 of the 96 bytes at `0x08`-`0x67` |
| `0x08` | 16 | `ra sp gp tp s0 s1 ... s11` |
| `0x48` | 8 | `mstatus mie mtvec mscratch`, then 4 reserved words (0) |

CRC-32: IEEE 802.3, reflected, polynomial `0xEDB88320`, initial value and final
XOR `0xFFFF_FFFF` (zlib `crc32`; check value `crc32("123456789")` =
`0xCBF4_3926`). Words are little-endian.

`pm_suspend()` is an ordinary function call, so caller-saved registers need
not be saved (setjmp/longjmp semantics: `pm_ctx_save` returns 0 when it saves
and 1 when the ROM resumes through `pm_ctx_restore`). `mstatus` is restored
last, so interrupts stay disabled until the whole context is back.

## PMU scratch registers (doc/SOC_REGMAP.md)

| Register | Value while a context is pending |
|---|---|
| `SCRATCH0` (`0x2000_3010`) | `CTX_ADDR` (`0x1000_0040`); any other value rejects the resume |
| `SCRATCH1` (`0x2000_3014`) | resume magic `0x5E5E_0A0A` |

Both are in PD_AON and survive SLEEP and DEEP_SLEEP.

## Power-down (application, `pm_suspend`)

Follows doc/SOC_REGMAP.md "Low-power entry":

1. Wake sources enabled in `mie` (and at their origin); `pm_suspend` returns
   `PM_EINVAL` if `mie` enables none. `mstatus.MIE` is cleared.
2. `pm_ctx_save(CTX_ADDR)`, then seal: CRC, then magic.
3. `SCRATCH0 = CTX_ADDR`, `SCRATCH1 = 0x5E5E_0A0A`.
4. `pm_clean_and_wfi` (assembly, no stack): `mcachectl` bit 2 (D-cache clean),
   read `mcachectl` and abandon the entry if bit 31 (write-back error) is set
   (`PM_EWB`); write `PMU.CTRL = MODE | LP_EN`; `wfi`. No cached store follows
   the clean.
5. If `wfi` returns, the CPU was not powered down (the PMU refused the
   power-down, `STATUS.ERR_DIRTY`, or a wake event came first): clear
   `SCRATCH1` and the context magic, set `PMU.CTRL` back to IDLE mode, return
   `PM_ABORTED`. After a resume `pm_suspend` also sets the PMU mode back to
   IDLE (the mode register is sticky) and returns `PM_RESUMED`.

## Boot ROM (every power-up)

The CPU reset vector is the ROM base `0x0000_0000`. The ROM clears `x1`-`x31`,
sets up its stack and `.data`/`.bss` in `RAM_BASE + 0x400`..`0xFFF`, installs
its trap handler, then checks, in this order:

| # | Check | On failure (`boot_reason`) |
|---|---|---|
| 1 | `PMU.STATUS.RESUME` = 1 | cold boot (1, power-on) |
| 2 | `PMU.SCRATCH1` = `0x5E5E_0A0A` | cold boot (2) |
| 3 | `PMU.SCRATCH0` = `CTX_ADDR` | cold boot (3) |
| 4 | `ctx.magic` = `CTX1` | cold boot (4) |
| 5 | `ctx.crc` = CRC-32(`ctx.regs`, `ctx.arch`) | cold boot (5) |

`STATUS.WDT_RST` = 1 selects `rst_cause` WDT (the PMU clears RESUME on a
watchdog reset, so check 1 fails). In every case the ROM then writes 1 to
`STATUS.RESUME`, `STATUS.RESUME_DEEP` and `STATUS.WDT_RST` (W1C) and clears
`SCRATCH1`, so a context is restored at most once.

- **Resume** (all checks pass): record `rst_cause`, `boot_reason` = 0,
  `pmu_status`, `boot_status` = RESUMED, `resumes + 1`; clear `ctx.magic`;
  restore the context. Execution continues in the application's
  `pm_suspend()`, which returns `PM_RESUMED`. The ROM prints nothing.
- **Cold boot**: at power-on (`rst_cause` POR) clear the handoff block and the
  persistent area (RAM content is undefined at power-on); after a rejected
  resume keep both and count `bad_resumes`; after a watchdog reset keep both
  (`boot_status` COLD, `rst_cause` WDT: the debug application's post-mortem
  reads the error log and its mailbox in the persistent area). Record the handoff fields, clear
  `ctx.magic`, print the banner on the UART, then check the image (below). A
  valid image: D-cache clean (with the error check), I-cache invalidate, jump to
  `entry`. Otherwise (or on a write-back error) `boot_status` = NO_IMAGE and
  the ROM starts the UART monitor (`help peek poke regs go`).

## Application image

The image is read-only at run time: `app/crt0.S` copies `.data` from the
image (its load address, `__data_lma`) to its run-time address after the
image (`fw/platform/lpsoc/app.ld`), then clears `.bss`. So a cold boot without
a host reload (watchdog reset) finds the image unchanged and its CRC valid.

At `APP_BASE` = `RAM_BASE + 0x1000`, loaded by the host (the testbench
preloads it into the RAM model). 32-byte header, little-endian words:

| Offset | Field | Rule (checked by the ROM and by `tools/mkimage.py`) |
|---|---|---|
| `0x00` | magic | `0x5041_504C` ("LPAP") |
| `0x04` | version | 1 |
| `0x08` | load_addr | `APP_BASE` (`0x1000_1000`) |
| `0x0C` | size | bytes including the header; multiple of 4; at most `RAM_SIZE - 0x1000` |
| `0x10` | entry | inside the image after the header, 4-byte aligned |
| `0x14` | crc | CRC-32 of the `size - 32` bytes after the header |
| `0x18` | reserved | 0 |
| `0x1C` | reserved | 0 |

`fw/app/crt0.S` emits the header; `tools/mkimage.py app` checks every field
(an image that the ROM would reject is a build error) and patches the CRC.

## Host mailbox and test completion

The host (in simulation the testbench, `+bootarg=<hex>`) may write
`RAM_BASE + 0x100` = `0x4841_5247` ("HARG") and `RAM_BASE + 0x104` = boot
argument before the CPU starts. The application reads it through the uncached
alias. Boot argument: bit 31 run non-interactively, bit 30 start the monitor,
bits 15:0 test ID (`0xFFFF` = all). Without a valid mailbox the validation
application starts the UART monitor.

End of a run: the application prints a last UART line `PASS` (exit code 0)
or `FAIL 0x<code>`, stores the code in `handoff.signature` and stops in WFI
with no wake source. The SoC testbench ends the simulation on that line; its
verdict also requires every bench checker to be clean.

## Reconciliation (stage 2)

| Item | Stage-1 interim ABI (`fw/crt0.S`, main) | Firmware branch | This ABI | Reason |
|---|---|---|---|---|
| Resume detection | `STATUS.RESUME` + SCRATCH1 magic + pointer range + CRC | PMU `RST_CAUSE` register (2/3) + context magic + CRC | `STATUS.RESUME` + SCRATCH1 magic + SCRATCH0 = `CTX_ADDR` + context magic + CRC | doc/SOC_REGMAP.md has no reset-cause register; SCRATCH0/1 are defined there for exactly this; SPEC: restore only if the CRC matches |
| Context address | linker-placed `pm_ctx`, pointer in SCRATCH0 | fixed `RAM_BASE + 0x40` | fixed `CTX_ADDR` = `RAM_BASE + 0x40`, also in SCRATCH0 | one address; the ROM rejects any other pointer |
| Context layout | 20 words + CRC word | magic, CRC, 16 regs, 8 arch words | firmware branch layout (rv32m `arch[]`) | the branch layout carries a magic and reserves room; same CSRs as stage 1 |
| CRC | CRC-32/IEEE over 20 words | CRC-32/IEEE over 96 bytes | CRC-32/IEEE over 96 bytes | identical algorithm |
| Image | none (program in ROM) | header at `+0x1000`, CRC | firmware branch header, rebased to `0x1000_1000`, entry alignment checked | applications run from RAM; the ROM is one fixed program |
| Persistent RAM | last 256 bytes of RAM | `+0x200`, 512 B | `+0x200`, 512 B | firmware branch layout |
| Boot argument / exit | none / UART `PASS`/`FAIL` | testbench device at `0x4F00_0000` | RAM host mailbox / UART `PASS`/`FAIL` | doc/SPEC.md map has no such device; unmapped addresses return SLVERR |
| Software reset | - | PMU `SWRST` register | none | not in doc/SOC_REGMAP.md |
