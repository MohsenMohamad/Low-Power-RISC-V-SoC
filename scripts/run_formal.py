#!/usr/bin/env python3
"""Run every SymbiYosys job: each proof together with its cover run
(doc/SPEC.md: every formal proof has a cover run proving its assumptions are
not vacuous). Writes <out>/results.json (id "<sby>:<task>") and returns
nonzero if any job does not finish with status PASS, or if a cover run
reports an unreached cover statement."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JOBS = ["pmu:prove", "pmu:cover", "dvfs_mux:prove", "dvfs_mux:cover",
        "async_fifo:prove", "async_fifo:cover", "cdc_snapshot:prove", "cdc_snapshot:cover"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sby", default="sby")
    ap.add_argument("--out", default=os.path.join(ROOT, "build/formal"))
    ap.add_argument("--only", default="")
    ap.add_argument("--formal-dir", default=os.path.join(ROOT, "formal"))
    ap.add_argument("--timeout", type=int, default=7200)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    jobs = [j for j in JOBS if not a.only or j in a.only.split(",")]
    results, bad = [], 0
    for job in jobs:
        f, t = job.split(":")
        d = os.path.join(out, f"{f}_{t}")
        shutil.rmtree(d, ignore_errors=True)
        t0 = time.time()
        try:
            p = subprocess.run([a.sby, "-d", d, f"{f}.sby", t], cwd=a.formal_dir, capture_output=True,
                               text=True, timeout=a.timeout)
            log, rc = p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            log, rc = "timeout", 124
        open(os.path.join(out, f"{f}_{t}.log"), "w").write(log)
        status = "PASS" if (rc == 0 and re.search(r"DONE \(PASS", log)
                            and "Unreached cover" not in log) else "FAIL"
        reached = len(set(re.findall(r"Reached cover statement at (\S+)", log)))
        info = f"{reached} cover statements reached" if t == "cover" else \
            ("; ".join(sorted(set(m for m in re.findall(r"summary: (.*successful proof.*)", log)))) or "")
        print(f"  {job:22s} {status}  {time.time() - t0:6.0f}s  {info}")
        if status != "PASS":
            bad += 1
            print("    " + "\n    ".join([l for l in log.splitlines()
                                         if re.search(r"FAIL|Unreached|ERROR|Assert failed", l)][:10]))
        results.append({"id": job, "status": status, "seconds": round(time.time() - t0), "reached": reached})
    json.dump(results, open(os.path.join(out, "results.json"), "w"), indent=1)
    print(f"FORMAL: {len(jobs) - bad}/{len(jobs)} jobs passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
