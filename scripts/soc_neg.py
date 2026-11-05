#!/usr/bin/env python3
"""Negative tests of the SoC testbench (sim/tb_soc.sv). Each run must FAIL, and
must fail for the reason it provokes; a run that passes (or fails for an
unrelated reason) fails this script.

  iso-verilator  isolation defeated while PD_CPU is off: random OFF values
                 reach PD_AON and the SVA / protocol checks must fire
  iso-icarus     same, 4-state: X from the corruption model must be detected
  fw-fail        firmware prints "FAIL ...": the bench must not pass
  timeout        no verdict before +timeout: the bench must fail
  short-reset    a PD_CPU reset shorter than the mtime-crossing requirement
"""
import argparse
import json
import os
import shlex
import subprocess
import sys


def run(cmd, log, timeout=3600):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        out, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        out, rc = "wall-clock timeout", 124
    open(log, "w").write(cmd + "\n" + out)
    return rc, out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vl", required=True)
    ap.add_argument("--iv", required=True)
    ap.add_argument("--fw", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rom = os.path.join(a.fw, "rom.hex")
    pm = f"{rom} +ram={os.path.join(a.fw, 'pm_test.hex')}"
    nf = f"{rom} +ram={os.path.join(a.fw, 'neg_fail.hex')}"
    cov = os.path.join(a.out, "cov.txt")
    cases = [
        ("iso-verilator", f"{a.vl} +rom={pm} +cov={cov} +break_iso",
         lambda out: "Assertion failed" in out or "[tb] ERROR" in out),
        ("iso-icarus", f"{a.iv} +rom={pm} +cov={cov} +break_iso +timeout=6000000",
         lambda out: "[tb] ERROR" in out and "unknown" in out),
        ("fw-fail", f"{a.vl} +rom={nf} +cov={cov}",
         lambda out: "firmware=fail" in out),
        ("timeout", f"{a.vl} +rom={pm} +cov={cov} +timeout=200000",
         lambda out: "FAIL: timeout" in out),
        ("short-reset", f"{a.vl} +rom={pm} +cov={cov} +neg_short_rst +timeout=3000000",
         lambda out: "PD_CPU reset lasted only" in out),
    ]
    results, bad = [], 0
    for cid, cmd, reason in cases:
        rc, out = run(cmd, os.path.join(a.out, cid + ".log"))
        passed_bench = rc == 0 and "TEST PASSED" in out
        detected = (not passed_bench) and rc != 0 and reason(out)
        print(f"  {cid:14s} {'OK: failure detected' if detected else 'NOT DETECTED'} (exit {rc})")
        if not detected:
            bad += 1
            print("    " + "\n    ".join(out.splitlines()[-8:]))
        results.append({"id": f"soc-neg/{cid}", "status": "PASS" if detected else "FAIL"})
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    print(f"SOC-NEG: {len(cases) - bad}/{len(cases)} negative tests detected")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
