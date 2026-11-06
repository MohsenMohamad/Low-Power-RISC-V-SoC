#!/usr/bin/env python3
"""Run the debug-block unit testbenches (verif/debug) and their negative tests.

Every positive test runs once per seed; the trace tests run at every
supported buffer depth (16, 32, 64, 128). A positive run passes only if the
simulator exits 0, prints "TEST PASSED" and prints no %Error / failed
assertion / CHECK FAILED line. A negative test passes only if the run FAILS
and its log shows the failure it was built to provoke (doc/SPEC.md: every
checker has a negative test).

Writes <out>/results.json (ids "<test>/seed<n>" and "neg/<name>"), one log
and one Verilator coverage file per run. Exit status 0 only if every run
passed; scripts/check_results.py then checks the ids against
dv/regress/dbg_unit.required.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys

DEPTHS = (16, 32, 64, 128)
# (test id prefix, binary relative to --build, +TEST name)
TESTS = [(f"trace_rand_d{d}", f"tb_trace_d{d}/Vtb_trace", "trace_rand") for d in DEPTHS] + \
        [(f"trace_pwroff_d{d}", f"tb_trace_d{d}/Vtb_trace", "trace_pwroff") for d in DEPTHS] + [
    ("evcnt_rand", "tb_evcnt/Vtb_evcnt", "evcnt_rand"),
    ("evcnt_pwr", "tb_evcnt/Vtb_evcnt", "evcnt_pwr"),
    ("errlog_rand", "tb_errlog/Vtb_errlog", "errlog_rand"),
    ("wdt_rand", "tb_wdt/Vtb_wdt", "wdt_rand"),
    ("wdt_lock", "tb_wdt/Vtb_wdt", "wdt_lock"),
    ("subsys_smoke", "tb_subsys/Vtb_subsys", "subsys_smoke"),
    ("subsys_wdt_chain", "tb_subsys/Vtb_subsys", "subsys_wdt_chain"),
]
# (id, binary, plusargs, regex the failing log must contain)
NEG = [
    # every captured trace timestamp forced to 0: the timestamp window check fails
    ("neg/trace_ts_zero", "tb_trace_d32/Vtb_trace", ["+TEST=trace_rand", "+neg_ts_zero"],
     r"CHECK FAILED: .*TS 0x00000000 outside"),
    # response valids high during reset: a_rst_valid (no longer vacuous) fires
    ("neg/axil_rst", "tb_neg/Vtb_neg", ["+TEST=neg_axil_rst"], r"Assertion failed in .*a_rst_valid"),
]
BAD_RE = re.compile(r"%Error|Assertion failed|CHECK FAILED|TEST FAILED|TIMEOUT")


def run(build, out, rid, binary, args, timeout):
    d = os.path.join(out, rid.replace("/", "_"))
    os.makedirs(d, exist_ok=True)
    cmd = [os.path.join(build, binary)] + args + [f"+verilator+coverage+file+{d}/coverage.dat"]
    try:
        p = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=timeout)
        log, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log, rc = out + "\n%Error: wall-clock timeout", 124
    except OSError as e:
        log, rc = f"%Error: cannot run {cmd[0]}: {e}", 127
    open(os.path.join(d, "run.log"), "w").write(" ".join(cmd) + "\n" + log)
    return log, rc, d


def positive(build, out, rid, binary, test, seed, timeout):
    log, rc, d = run(build, out, rid, binary, [f"+TEST={test}", f"+seed={seed}", f"+verilator+seed+{seed}"],
                     timeout)
    ok = rc == 0 and "TEST PASSED" in log and not BAD_RE.search(log)
    m = re.search(r"RESULT test=\S+ seed=\d+ checks=(\d+) errors=(\d+)", log)
    return {"id": rid, "status": "PASS" if ok else "FAIL", "checks": int(m.group(1)) if m else 0,
            "errors": int(m.group(2)) if m else -1, "log": os.path.join(d, "run.log"),
            "first_error": next((l for l in log.splitlines() if BAD_RE.search(l)), "")}


def negative(build, out, rid, binary, args, pattern, timeout):
    log, rc, d = run(build, out, rid, binary, args, timeout)
    failed = rc != 0 or "TEST PASSED" not in log or BAD_RE.search(log)
    detected = bool(failed and re.search(pattern, log))
    return {"id": rid, "status": "PASS" if detected else "FAIL", "log": os.path.join(d, "run.log"),
            "detail": "expected failure reported" if detected else
            ("run did not fail (checker silent)" if not failed else f"failed without /{pattern}/")}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True, help="verif/debug build directory")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seeds", default="1 2 3")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()
    a.build, a.out = os.path.abspath(a.build), os.path.abspath(a.out)
    os.makedirs(a.out, exist_ok=True)
    work = [("pos", f"{t}/seed{s}", b, n, int(s)) for t, b, n in TESTS for s in a.seeds.split()]
    work += [("neg", rid, b, args, pat) for rid, b, args, pat in NEG]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda w: positive(a.build, a.out, w[1], w[2], w[3], w[4], a.timeout) if w[0] == "pos"
                          else negative(a.build, a.out, w[1], w[2], w[3], w[4], a.timeout), work))
    for r in res:
        line = f"  {r['status']:4s} {r['id']:30s}"
        if "checks" in r:
            line += f" {r['checks']:7d} checks"
        if r["status"] != "PASS":
            line += "  " + (r.get("first_error") or r.get("detail", ""))
        elif "detail" in r:
            line += "  " + r["detail"]
        print(line)
    json.dump(res, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    npass = sum(r["status"] == "PASS" for r in res)
    print(f"DBG-UNIT: {npass}/{len(res)} runs passed ({sum(r.get('checks', 0) for r in res)} checks)")
    return 0 if npass == len(res) else 1


if __name__ == "__main__":
    sys.exit(main())
