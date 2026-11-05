#!/usr/bin/env python3
"""Run the SystemVerilog unit testbenches (caches, AXI mux) over a set of seeds and summarise."""
import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys

BENCHES = {"dcache": "dc/Vtb_dcache", "icache": "ic/Vtb_icache", "axilmux": "mux/Vtb_axil_mux"}


def run(build, bench, seed, n):
    d = os.path.join(build, bench, f"seed{seed}")
    os.makedirs(d, exist_ok=True)
    cmd = [os.path.join(build, BENCHES[bench]), f"+seed={seed}", f"+n={n}"]
    try:
        p = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=3600)
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        out = "wall-clock timeout"
        p = None
    open(os.path.join(d, "run.log"), "w").write(out)
    ok = p is not None and p.returncode == 0 and f"[tb_{bench}] PASS" in out and "%Error" not in out \
        and "Assertion failed" not in out
    stats = {}
    m = re.search(r"\[%s\] requests=(\d+) checks=(\d+) error_responses=(\d+) retractions=(\d+) "
                  r"maint_ops=(\d+) mem_word_checks=(\d+) stale_ok=(\d+) mismatches=(\d+)" % bench, out)
    if m:
        stats = dict(zip(["requests", "checks", "error_responses", "retractions", "maint_ops",
                          "mem_word_checks", "stale_ok", "mismatches"], map(int, m.groups())))
    errs = [l for l in out.splitlines() if "%Error" in l or "FAIL" in l or "Assertion" in l][:5]
    return {"bench": bench, "seed": seed, "pass": ok, "errors": errs, **stats}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build", required=True)
    ap.add_argument("--seeds", default="1 2 3 4")
    ap.add_argument("--n", type=int, default=8000)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    a = ap.parse_args()
    work = [(b, int(s)) for b in BENCHES for s in a.seeds.split()]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda w: run(a.build, w[0], w[1], a.n), work))
    for r in res:
        if not r["pass"]:
            print(f"{r['bench']} seed {r['seed']}: FAIL\n  " + "\n  ".join(r["errors"]))
    summary = {}
    for b in BENCHES:
        rs = [r for r in res if r["bench"] == b]
        summary[b] = {"runs": len(rs), "pass": sum(r["pass"] for r in rs),
                      **{k: sum(r.get(k, 0) for r in rs) for k in
                         ("requests", "checks", "error_responses", "retractions", "maint_ops",
                          "mem_word_checks", "stale_ok", "mismatches")}}
        s = summary[b]
        if b == "axilmux":
            print(f"UNITTEST {b}: {s['pass']}/{s['runs']} seeds passed")
            continue
        print(f"CACHETEST {b}: {s['pass']}/{s['runs']} seeds passed, {s['checks']} responses checked, "
              f"{s['error_responses']} error responses, {s['maint_ops']} maintenance ops, "
              f"{s['mem_word_checks']} post-maintenance memory checks, {s['mismatches']} mismatches")
    json.dump({"summary": summary, "results": res}, open(os.path.join(a.build, "summary.json"), "w"), indent=1)
    json.dump([{"id": f"{r['bench']}/seed{r['seed']}", "status": "PASS" if r["pass"] else "FAIL"} for r in res],
              open(os.path.join(a.build, "results.json"), "w"), indent=1)
    sys.exit(0 if all(r["pass"] for r in res) else 1)


if __name__ == "__main__":
    main()
