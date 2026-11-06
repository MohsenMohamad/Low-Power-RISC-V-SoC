#!/usr/bin/env python3
"""Top-level regression driver behind `make test` (doc/SPEC.md: a single
top-level `make test` runs everything that runs on open-source tools).

Runs every step below in order (a failing step does not stop the run, so one
run reports everything), logs each to build/regress/<step>.log, records one
result per step ID and checks the set against dv/regress/top.required: a
missing, failing or unknown step fails the run. Each step itself checks its
own required-test list (cosim seeds, arch tests, cache seeds, formal jobs,
mutants, negative tests) and exits nonzero on any failure.

Exit status: 0 only if every required step passed.
"""
import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STEPS = [
    ("toolchain",            "make toolchain"),
    ("lint",                 "make lint"),
    ("fw",                   "make fw"),
    ("cpu/cosim",            "make cosim"),
    ("cpu/archtest",         "make archtest"),
    ("cpu/cachetest",        "make cachetest"),
    ("cpu/coverage",         "make coverage"),
    ("soc/pm_test-verilator", "make sim"),
    ("soc/boot_test-verilator", "make boot"),
    ("soc/pm_test-icarus",   "make sim-x"),
    ("soc/boot_test-icarus", "make boot-x"),
    ("soc/negative",         "make sim-neg"),
    ("fw/suite-soc",         "make fw-suite"),
    ("fw/suite-spike",       "make fw-spike"),
    ("fw/monitor",           "make fw-monitor"),
    ("fw/negative",          "make fw-neg"),
    ("debug/unit",           "make dbg-unit"),
    ("debug/soc",            "make dbg-integ"),
    ("debug/bench",          "make bench"),
    ("pmu/unit",             "make sim-pmu"),
    ("formal",               "make formal"),
    ("mutation",             "make mutation"),
    ("selftest",             "make selftest"),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(ROOT, "build/regress"))
    ap.add_argument("--only", default="", help="comma-separated step IDs (the run then fails as incomplete)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    results = []
    t_all = time.time()
    for sid, cmd in STEPS:
        if a.only and sid not in a.only.split(","):
            continue
        log = os.path.join(a.out, sid.replace("/", "_") + ".log")
        t0 = time.time()
        print(f"== {sid}: {cmd}", flush=True)
        with open(log, "w") as f:
            p = subprocess.run(cmd, shell=True, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
        status = "PASS" if p.returncode == 0 else "FAIL"
        dt = time.time() - t0
        results.append({"id": sid, "status": status, "seconds": round(dt), "log": os.path.relpath(log, ROOT)})
        summary = [l.rstrip() for l in open(log, errors="replace")
                   if l.startswith(("COSIM:", "ARCHTEST:", "CACHETEST", "UNITTEST", "COVERAGE:", "RESULTS",
                                    "SOC-COV", "SOC-NEG:", "FW-RUN:", "DBG-UNIT:", "BENCH ", "  PASS dbg", "  FAIL dbg", "  fw-neg", "  monitor ", "  spike --priv", "FORMAL:", "MUTATION:", "SELFTEST:", "TOOLCHAIN:",
                                    "[tb] TEST", "== SoC lint", "== CPU lint", "== debug lint", "  coverage holes"))]
        for l in summary[-12:]:
            print("   " + l)
        print(f"   -> {status} ({dt:.0f} s, log {os.path.relpath(log, ROOT)})", flush=True)
    path = os.path.join(a.out, "results.json")
    json.dump(results, open(path, "w"), indent=1)
    print(f"\n== make test summary ({time.time() - t_all:.0f} s)")
    for r in results:
        print(f"   {r['status']:5s} {r['id']:26s} {r['seconds']:6d} s")
    rc = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/check_results.py"), "--name", "make test",
                         "--results", path, "--required", os.path.join(ROOT, "dv/regress/top.required")]).returncode
    print("== make test: PASS" if rc == 0 else "== make test: FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
