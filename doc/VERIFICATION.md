# Verification of the CPU subsystem

Scope: `core_top`, `icache`, `dcache` and `axil_mux2` (via `cpu_top`). All results below were produced in this repository's environment with the tool versions listed in the README. `make test` reproduces them.

## Flows

| Flow | DUT | Reference / checker | Stimulus |
|---|---|---|---|
| Lockstep co-simulation (`make cosim`) | `cpu_top` (core + both caches + mux) | Spike (libriscv) stepped once per RTL commit event; final RAM image compare | random programs from `dv/cosim/gen_rand.py`, directed tests in `sw/tests` |
| riscv-arch-test (`make archtest`) | `cpu_top` | signature from standalone Spike, plus lockstep Spike during the run | rv32i_m I, M, Zifencei, privilege (release 3.9.1) |
| Cache unit testbenches (`make cachetest`) | `dcache`, `icache` | reference memory model, replacement-policy model, SVA | class-based constrained random (`randomize()`), directed phases |
| AXI mux unit testbench | `axil_mux2` | per-master memory model, SVA | two constrained-random masters with random RREADY/BREADY |
| Lint (`make lint`) | all RTL | `verilator --lint-only -Wall` | – |
| Coverage (`make coverage`) | all of the above | ISA plan bins, SVA cover properties, covergroups, line/toggle/expression | – |
| Mutation analysis (`scripts/mutation.py`) | 17 injected RTL bugs | all flows above | – |

### Lockstep co-simulation

The Verilator C++ testbench (`dv/cosim/tb_main.cpp`) works as follows:

- **Memory and stimulus:** drives `cpu_top` against an AXI4-Lite memory model (`dv/common/axil_mem.h`). The model supports random READY, random response latency, DECERR outside RAM/MMIO, and an MMIO block for raising and clearing interrupts.
- **Lockstep compare:** each commit-trace event (retire, exception or interrupt entry) steps Spike once (`dv/cosim/spike_cosim.cpp`, a custom `simif_t` with its own memory copy). It compares:
  - pc and next pc
  - rd write
  - store address, size and data
  - trap cause, `mepc` and `mtval`
- **Interrupt synchronisation:** each event carries the `mip` value the RTL used, and Spike's `mip` is set to that value before the step. This makes interrupt timing and `csrr mip` reads deterministic.
- **Implementation-specific values:** CSR reads of cycle/time counters and `marchid`/`mimpid` copy the RTL result into Spike.
- **End of test:** the program cleans the D-cache (`fence.i`), then the whole 4 MB RAM image is compared with Spike's.

Random program content:

- ALU and M-extension ops with corner operands
- Aligned and misaligned loads/stores, cache-aliasing addresses (2 KB stride → evictions), uncached MMIO accesses, unmapped addresses → access faults
- Forward branches, counted loops, JAL/JALR including misaligned targets
- CSR accesses: legal, read-only-write, non-existent
- `ecall`/`ebreak`, illegal and field-fuzzed encodings
- `fence`, `fence.i`, self-modifying code
- `wfi`, software-raised and random external interrupts

Programs run in direct or vectored `mtvec` mode, under four AXI back-pressure/latency settings and four interrupt rates (selected by seed).

### Cache and bus unit testbenches (SystemVerilog, Verilator `--timing`)

`dv/cache/cache_tb_pkg.sv` provides:

- **`cache_txn`:** constrained-random request with region, op, size/offset, gap and retraction. Regions are: two hot sets with 8 tags, random, sequential, uncached, DECERR window, poisoned lines.
- **`axil_slave`:** random READY/latency, read and write error injection.
- **`cache_agent`:** drives the core port, checks every response against the reference memory and every word in backing memory after each clean/flush, and models I-cache staleness. Stale data is accepted only until the next invalidation.
- **`repl_model`:** 2-way LRU replacement reference. It checks hit/miss, hit way and victim of every lookup.

The D-cache bench runs these phases:

1. Baseline traffic
2. Back-pressure with random clean/flush
3. Hot-set eviction storm
4. Directed write-back-error reporting (a dirty line is poisoned, then cleaned; `wb_err` must set, then clear on the next operation)
5. Mixed traffic and a final flush

The I-cache bench adds a coherence scenario: backing memory is modified behind the cache, then invalidated.

SVA checks:

- AXI address/data stable while VALID && !READY
- No X on control signals
- Aligned addresses
- At most one outstanding core request; responses only with an outstanding request
- No grant during maintenance; `done` only while requested
- I-cache: all lines invalid after invalidate
- Mux: response routing and handshake equivalence

## Results (`make test`, clean build)

| Flow | Result |
|---|---|
| Lint | clean (`-Wall`, no warnings) |
| Directed tests | 2/2 pass (`smoke` in lockstep; `cachectl` self-checking, custom CSR not known to Spike), each with and without AXI back-pressure |
| Random co-simulation | **200/200 seeds pass**: 1,004,966 instructions, 20,238 exceptions and 18,385 interrupts compared against Spike, plus final memory image compare per seed |
| riscv-arch-test | **63/63 applicable tests pass**: I 39/39, M 8/8, Zifencei 1/1, privilege 15/15 (19,152 signature words compared) |
| D-cache bench | **8/8 seeds pass**: 64,008 responses checked (5,453 expected bus-error responses), 845 clean/flush operations, 1,186,823 post-maintenance memory-word checks, 0 mismatches, 0 assertion failures |
| I-cache bench | **8/8 seeds pass**: 72,000 responses checked (4,165 expected bus-error responses), 686 invalidations, 0 mismatches, 0 replacement-policy errors, 0 assertion failures |
| Replacement-policy model | 118,434 cache lookups checked (hit/miss, hit way, victim) across both benches, 0 errors |
| AXI mux bench | **8/8 seeds pass** (8,000 transactions per seed from two masters, random RREADY/BREADY) |
| Mutation analysis | **17/17 injected bugs detected** (12/17 initially; gaps closed, see below) |

### Soak run

`python3 scripts/run_cosim.py --first-seed 1001 --seeds 1000 --length 6000`:
**1000/1000 seeds pass**: 10,055,197 instructions, 202,014 exceptions and 190,536 interrupts compared against Spike, over 97.6 M simulated cycles, each with a final memory image compare.

### Coverage (merged over all flows)

| Metric | Result |
|---|---|
| ISA plan bins (commit trace) | 127/127: every RV32IM/Zicsr/Zifencei instruction retired; all 9 exception causes; all 3 interrupt causes; every branch taken and not taken; every legal load/store size × byte offset; corner result values; every destination register |
| SVA cover properties | 66/67. Hole: `cp_wb_error` in the system context (the co-simulation memory never fails a cacheable write). The scenario is covered by the D-cache bench (directed write-back-error phase, covergroup bin `cg_maint.cp_wb_err.err`). |
| Covergroup bins | 73/73 |
| RTL line | 244/253 (96.4%). All 9 uncovered points are unreachable `default:` arms of fully decoded `case` statements. |
| RTL expression | 617/622 (99.2%) |
| RTL toggle | 14,901/17,092 (87.2%). Remaining: upper bits of 64-bit counters, address MSBs outside the tested regions, tied-off ports. |

Details: `build/coverage/report.md`. Verilator 5.052 records covergroup bins in `coverage.dat` but does not implement `get_coverage()`, so bins are reported from the database.

## Bugs and issues found

### RTL bugs

| # | Found by | Description | Fix |
|---|---|---|---|
| 1 | random co-simulation (11 of the first 40 seeds) | For an illegal instruction whose low bits are not `11` (a 16-bit encoding, no C extension), `mtval` reported all 32 fetched bits. The faulting instruction is only the 16-bit parcel, so `mtval` must hold the zero-extended low half (as Spike does). | `core_top.sv` ID exception tval |
| 2 | random co-simulation | With no PMP implemented, the core treated `pmpcfg*`/`pmpaddr*` as read-zero CSRs, but the reference (Spike, 0 PMP regions) treats them as non-existent. The privileged spec permits either; aligned with the reference so absence of PMP is visible to software. | `core_csr.sv` CSR decode |
| 3 | code review before first simulation | D-cache maintenance scan: if the last line (set 127, way 1) was dirty, the write-back path returned to the scan, which wrapped around to set 0 and never terminated. | `dcache.sv` `fl_last` |
| 4 | code review before first simulation | Divider was not cancelled by a pipeline flush; a squashed divide could later deliver its result to the next divide. | `core_muldiv.sv` `div_kill` |
| 5 | code review before first simulation | `mcachectl` write detection compared an unrelated immediate field. | `core_top.sv` |

### Reference-model differences (not bugs, documented)

- `misa` is read-only in this core. In Spike it is writable and can clear extensions (e.g. disable M). Both are legal WARL behaviour. The random generator therefore never writes `misa`.

### Testbench / generator bugs found by the co-simulation itself

These showed up as RTL and Spike agreeing on a test that did something unintended. They are listed because they affected test quality.

1. Generator listed `mtvec` as read-only, so its "write to read-only CSR" case overwrote `mtvec`, giving an endless trap loop.
2. Co-simulation harness wrote overridden CSR values into Spike zero-extended. Spike keeps RV32 registers sign-extended, so a later signed compare diverged.
3. Generator epilogue used the trap handler's scratch registers. An interrupt between `la` and `sw tohost` redirected the final store.
4. Operator precedence in the "custom-0 illegal" template left the opcode random, occasionally producing a valid far `jal`.
5. Multi-register snippets could pick the same temporary for address and data.
6. riscv-arch-test ELFs had no `_start`, so the entry point was wrong; now linked with `-e rvtest_entry_point`.
7. SV benches:
   - static block-variable initialiser evaluated at time 0
   - random cache maintenance was never scheduled while a response was pending
   - `dist` constraints were ~12× slower under Verilator's SMT-based solver and, combined with mode constraints, unsatisfiable; replaced by selector constraints

### Mutation analysis

`scripts/mutation.py` applies one RTL mutation at a time in a scratch copy and runs the co-simulation (24 seeds) and, for cache/bus mutants, the unit benches.

| Mutant | Detected by |
|---|---|
| MEM→EX forwarding removed | co-simulation |
| CSR read not treated as a late result | co-simulation |
| forwarded operand not captured while EX is held | co-simulation |
| stores may issue under an older trapping instruction | co-simulation (after adding ecall shadow stores) |
| interrupt taken without draining the pipeline | co-simulation |
| `mret` does not set MPIE | co-simulation |
| REM uses quotient sign | co-simulation |
| illegal shift-immediate encodings accepted | co-simulation (after adding field-fuzzed encodings) |
| stale fetch responses not discarded after redirect | co-simulation |
| D$ store hit does not set dirty | co-simulation, D$ bench |
| D$ LRU updated towards the hit way (performance only) | D$ bench replacement model (added) |
| D$ maintenance scan skips way 1 of last set | co-simulation |
| D$ refill bus error ignored | D$ bench |
| D$ uncached store writes all byte lanes | D$ bench |
| I$ invalidate misses way 1 | co-simulation, I$ bench |
| I$ always evicts way 0 (performance only) | I$ bench replacement model (added) |
| AXI mux releases read path without RREADY | AXI mux bench (added; the caches never deassert RREADY, so this bug is invisible in-system) |

The first run detected 12/17. The five survivors identified real verification gaps, which were closed as noted (generator, replacement-policy model, mux bench). All 17 are now detected.

## Not covered / limitations

- **Spec gaps:** UVM is not used, since Verilator does not support it. Formal verification (SymbiYosys) is specified for the PMU, which is not implemented yet.
- **Interrupt timing:** interrupt lines are synchronous inputs in these benches. Clock-domain crossing and the PMU clock-gating path are not exercised.
- **Not co-simulated:** `mcachectl` (custom CSR, unknown to Spike); it is checked by the self-checking directed test and the D-cache bench. Timing-dependent CSR values (`mcycle`, `time`) are taken from the RTL.
- **Reference choice:** arch-test reference signatures come from Spike (riscof's Spike plugin approach), not Sail.
