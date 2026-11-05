#!/usr/bin/env python3
"""Mutation analysis: check that the verification flows detect injected RTL bugs.

Each mutant is a single textual edit of one RTL file, made in a scratch copy of
the repository. Core/bus mutants are run against the Spike lockstep regression
(a reduced seed set plus the arch-test smoke subset); cache mutants are also run
against the SystemVerilog unit testbenches (caches, AXI mux). A mutant is "killed" if any flow
fails.

The run fails (exit 1, doc/SPEC.md verification rules) if any mutant SURVIVED,
failed to build (BUILD-FAIL) or could not be applied because the RTL text no
longer matches (NOT-APPLIED), unless the mutant is listed with a reason in the
waiver file (--waivers, default dv/mutation_waivers.txt, "<id>  # reason").
Waivers without a reason and waivers for unknown mutant ids are errors.
--mutants <json> replaces the built-in list (used by the negative tests).
"""
import argparse
import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MUTANTS = [
    # (id, file, old, new, description, run cache TB)
    ("fwd_mem_rs1", "rtl/core/core_top.sv",
     "    if (mem_valid && mem_ctrl.rd_we && mem_ctrl.rd == ex_ctrl.rs1) ex_rs1 = mem_result;\n", "",
     "EX->EX forwarding from MEM removed for rs1", False),
    ("hazard_csr", "rtl/core/core_top.sv",
     "(ex_ctrl.is_load || ex_ctrl.is_csr)", "(ex_ctrl.is_load)",
     "CSR-read result not treated as late (no use stall)", False),
    ("hold_capture", "rtl/core/core_top.sv",
     "      ex_rs1_q <= ex_rs1;\n      ex_rs2_q <= ex_rs2;\n", "",
     "forwarded operands not captured while EX is held", False),
    ("mem_issue_ok", "rtl/core/core_top.sv",
     "assign mem_issue_ok  = !wb_valid || (wb_commit && !wb_flush);", "assign mem_issue_ok  = 1'b1;",
     "stores may issue under an older trapping instruction", False),
    ("irq_no_drain", "rtl/core/core_top.sv",
     "irq_take && f_valid && !ex_valid && !mem_valid && !wb_valid &&",
     "irq_take && f_valid &&",
     "interrupt taken without draining the pipeline", False),
    ("mret_mpie", "rtl/core/core_csr.sv",
     "        mstatus_mpie_q <= 1'b1;\n", "",
     "mret does not set MPIE", False),
    ("rem_sign", "rtl/core/core_muldiv.sv",
     "result_q <= neg_r_q ? (~r + 32'd1) : r;", "result_q <= neg_q_q ? (~r + 32'd1) : r;",
     "REM uses quotient sign", False),
    ("srai_decode", "rtl/core/core_decoder.sv",
     "ctrl.illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);", "ctrl.illegal = 1'b0;",
     "illegal shift-immediate encodings accepted", False),
    ("fetch_discard", "rtl/core/core_fetch.sv",
     "discard_q <= outst_q - CW'(imem_rvalid_i);", "discard_q <= '0;",
     "stale fetch responses not discarded after redirect", False),
    ("dc_dirty", "rtl/cache/dcache.sv",
     "if (rq_we_q) dirty_q[hit_way][rq_idx] <= 1'b1;", "",
     "D$ store hit does not mark the line dirty", True),
    ("dc_lru", "rtl/cache/dcache.sv",
     "            lru_q[rq_idx] <= !hit_way;\n", "            lru_q[rq_idx] <= hit_way;\n",
     "D$ LRU updated towards the hit way", True),
    ("dc_flush_way1", "rtl/cache/dcache.sv",
     "assign fl_last = (line_idx_q == IDX_W'(SETS - 1)) && victim_q;",
     "assign fl_last = (line_idx_q == IDX_W'(SETS - 1));",
     "D$ maintenance scan ends before way 1 of the last set", True),
    ("dc_refill_err", "rtl/cache/dcache.sv",
     "          end else if (rf_err_q || m_rresp[1]) begin\n            rvalid_o = 1'b1;\n            err_o    = 1'b1;",
     "          end else if (1'b0) begin\n            rvalid_o = 1'b1;\n            err_o    = 1'b1;",
     "D$ refill bus error ignored", True),
    ("dc_wstrb", "rtl/cache/dcache.sv",
     "        m_wstrb   = rq_be_q;", "        m_wstrb   = 4'hF;",
     "D$ uncached store writes all byte lanes", True),
    ("ic_inval", "rtl/cache/icache.sv",
     "for (int w = 0; w < WAYS; w++) valid_q[w] <= '0;\n      end\n\n      unique case",
     "valid_q[0] <= '0;\n      end\n\n      unique case",
     "I$ invalidate misses way 1", True),
    ("ic_victim", "rtl/cache/icache.sv",
     "                      !valid_q[1][rq_idx] ? 1'b1 : lru_q[rq_idx];",
     "                      !valid_q[1][rq_idx] ? 1'b1 : 1'b0;",
     "I$ always evicts way 0 (performance-only bug)", True),
    ("mux_rd_owner", "rtl/bus/axil_mux2.sv",
     "P_RESP: if (m_rvalid && s_rready[rd_own_q]) begin rd_q <= P_IDLE; rd_last_q <= rd_own_q; end",
     "P_RESP: if (m_rvalid) begin rd_q <= P_IDLE; rd_last_q <= rd_own_q; end",
     "AXI mux releases read path without RREADY", True),
    # ---- CPU <-> SoC interface (doc/CPU_SOC_INTERFACE.md) ----
    ("wfi_no_hold", "rtl/core/core_top.sv",
     "else if (irq_wake && !wfi_hold_i)        wfi_sleep_q <= 1'b0;",
     "else if (irq_wake)                       wfi_sleep_q <= 1'b0;",
     "core leaves WFI while the PMU idle handshake is active", False),
    ("ack_not_quiescent", "rtl/cpu/cpu_top.sv",
     "assign quiescent = wfi_quiet && ic_idle && dc_idle && mux_idle;",
     "assign quiescent = wfi_quiet;",
     "idle_ack given while a cache / the bus mux is still busy", False),
    ("dc_clean_on_error", "rtl/cache/dcache.sv",
     "if (cnt_q == 2'd3 && wb_for_flush_q && !line_err_q && !m_bresp[1]) begin",
     "if (cnt_q == 2'd3 && wb_for_flush_q) begin",
     "D$ marks a line clean although its write-back failed (W35)", True),
    ("dc_evict_err_lost", "rtl/cache/dcache.sv",
     "            wb_err_q   <= evict_err_q;   // lost eviction data is reported by this op",
     "            wb_err_q   <= 1'b0;",
     "D$ eviction write-back error not reported by the next maintenance op (W35)", True),
    # (Removing only one of the two write-back state terms is an equivalent
    # mutant: each term alone keeps cache_clean low during a write-back.)
    ("dc_clean_during_evict", "rtl/cache/dcache.sv",
     "                 !(state_q inside {S_WB_RD, S_WB_W, S_WB_B, S_FL_TAG}) &&\n"
     "                 !(state_d inside {S_WB_RD, S_WB_W, S_WB_B, S_FL_TAG}) &&\n",
     "",
     "D$ reports clean while an eviction write-back is still in flight", True),
]


def sh(cmd, cwd, timeout=3600):
    try:
        p = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def one(args, m):
    mid, f, old, new, desc, cache = m
    work = os.path.join(args.out, mid)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    for d in ("rtl", "dv", "sw", "scripts", "mk"):
        if os.path.isdir(os.path.join(ROOT, d)):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(work, d))
    shutil.copy(os.path.join(ROOT, "Makefile"), work)
    src = open(os.path.join(work, f)).read()
    if old not in src:
        return {"id": mid, "desc": desc, "status": "NOT-APPLIED"}
    open(os.path.join(work, f), "w").write(src.replace(old, new, 1))
    killed_by = []
    rc, out = sh(f"make cosim-build VERILATOR={args.verilator} JOBS=1", work)
    if rc:
        return {"id": mid, "desc": desc, "status": "BUILD-FAIL", "log": out[-400:]}
    if cache:
        rc, out = sh(f"make -C dv/cache build VERILATOR={args.verilator} BUILD={work}/build/cachetest", work)
        if rc:
            return {"id": mid, "desc": desc, "status": "BUILD-FAIL", "log": out[-400:]}
    rc, out = sh(f"python3 scripts/run_cosim.py --bin build/cosim/obj/Vcosim --seeds {args.seeds} "
                 f"--length 2000 --jobs 1 --out build/cosim/mut --timeout 300", work)
    if rc:
        killed_by.append("cosim")
    if cache:
        rc, out = sh(f"make -C dv/cache VERILATOR={args.verilator} BUILD={work}/build/cachetest "
                     f"SEEDS='1 2' N=3000", work)
        if rc:
            killed_by.append("unit-tb")
    return {"id": mid, "desc": desc, "status": "KILLED" if killed_by else "SURVIVED",
            "killed_by": killed_by}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.path.join(ROOT, "build/mutation"))
    ap.add_argument("--seeds", type=int, default=24)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--verilator", default="verilator")
    ap.add_argument("--only", default="")
    ap.add_argument("--mutants", default="", help="JSON list replacing the built-in mutants")
    ap.add_argument("--waivers", default=os.path.join(ROOT, "dv/mutation_waivers.txt"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    mutants = MUTANTS
    if a.mutants:
        mutants = [tuple(m) for m in json.load(open(a.mutants))]
    known = {m[0] for m in mutants}
    waivers, errors = {}, []
    if os.path.exists(a.waivers):
        for n, line in enumerate(open(a.waivers), 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            body, _, reason = line.partition("#")
            mid = body.strip()
            if not reason.strip():
                errors.append(f"{a.waivers}:{n}: waiver without a reason: {line.strip()!r}")
            elif mid not in {m[0] for m in MUTANTS} | known:
                errors.append(f"{a.waivers}:{n}: waiver for unknown mutant {mid!r}")
            else:
                waivers[mid] = reason.strip()
    ms = [m for m in mutants if not a.only or m[0] in a.only.split(",")]
    if a.only and len(ms) != len(set(a.only.split(","))):
        errors.append(f"unknown mutant id in --only: {sorted(set(a.only.split(',')) - known)}")
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda m: one(a, m), ms))
    for r in res:
        bad = r["status"] != "KILLED"
        if bad and r["id"] in waivers:
            r["waived"] = waivers[r["id"]]
        print(f"{r['status']:12s} {r['id']:22s} {r['desc']}  {','.join(r.get('killed_by', []))}"
              + (f"  [waived: {r['waived']}]" if "waived" in r else ""))
        if r["status"] == "BUILD-FAIL":
            print("    " + r.get("log", "").replace("\n", "\n    ")[-400:])
    k = sum(r["status"] == "KILLED" for r in res)
    failed = [r["id"] for r in res if r["status"] != "KILLED" and "waived" not in r]
    print(f"MUTATION: {k}/{len(res)} mutants killed, "
          f"{sum('waived' in r for r in res)} waived, {len(failed)} failing: {failed}")
    for e in errors:
        print("  " + e)
    json.dump({"results": res, "failing": failed, "errors": errors},
              open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    json.dump([{"id": r["id"], "status": "PASS" if (r["status"] == "KILLED" or "waived" in r) else r["status"]}
               for r in res], open(os.path.join(a.out, "results.json"), "w"), indent=1)
    if failed or errors or not res:
        print("MUTATION: FAIL")
        return 1
    print("MUTATION: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
