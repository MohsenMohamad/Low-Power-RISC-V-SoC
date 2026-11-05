#!/usr/bin/env python3
"""riscv-arch-test (signature based, release 3.9.1) runner.

For every test in rv32i_m/{I,M,Zifencei,privilege}:
  1. evaluate the RVTEST_CASE conditions against this core's configuration
     (RV32IM_Zicsr_Zifencei, no hardware misaligned-access support) and collect
     the macro definitions of the satisfied cases (as riscof does)
  2. compile once; the same ELF runs on both models
  3. reference signature: standalone Spike (+signature)
  4. DUT signature: RTL testbench, which also runs Spike in lockstep
  5. compare signatures word by word
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISA = "RV32IMZicsr_Zifencei"
PARAMS = {"hw_data_misaligned_support": "False"}
SUITES = ["I", "M", "Zifencei", "privilege"]


def test_defines(src):
    """Return list of -D defines for satisfied RVTEST_CASEs (None if none apply)."""
    text = open(src).read()
    defines, any_ok = [], False
    for m in re.finditer(r'RVTEST_CASE\(\s*\d+\s*,\s*"([^"]*)"', text):
        ok = True
        for clause in m.group(1).replace("//", "").split(";"):
            clause = clause.strip()
            cm = re.match(r"check\s+ISA\s*:=\s*regex\((.*)\)$", clause)
            if cm:
                ok &= re.match(cm.group(1), ISA) is not None
                continue
            pm = re.match(r"check\s+(\w+)\s*:=\s*(\w+)$", clause)
            if pm:
                ok &= PARAMS.get(pm.group(1)) == pm.group(2)
        if ok:
            any_ok = True
            for clause in m.group(1).split(";"):
                dm = re.match(r"\s*def\s+(\w+)\s*=\s*(\w+)", clause)
                if dm:
                    defines.append(f"-D{dm.group(1)}={dm.group(2)}")
    return sorted(set(defines)) if any_ok else None


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timeout")


def one(args, suite, src):
    name = f"{suite}/{os.path.basename(src)[:-2]}"
    d = os.path.join(args.out, suite, os.path.basename(src)[:-2])
    os.makedirs(d, exist_ok=True)
    defs = test_defines(src)
    if defs is None:
        return {"test": name, "status": "N/A", "msg": "RVTEST_CASE conditions not met"}
    env = os.path.join(args.suite, "riscv-test-suite", "env")
    elf = os.path.join(d, "test.elf")
    cc = run([args.rv_prefix + "gcc", "-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-static",
              "-mcmodel=medany", "-fvisibility=hidden", "-nostdlib", "-nostartfiles",
              "-Wl,--no-warn-rwx-segments", "-Wl,-e,rvtest_entry_point", "-DXLEN=32", *defs,
              "-I", env, "-I", os.path.join(ROOT, "dv/archtest"),
              "-T", os.path.join(ROOT, "sw/common/link.ld"), src, "-o", elf])
    if cc.returncode:
        return {"test": name, "status": "ERROR", "msg": cc.stderr[-800:]}
    ref = os.path.join(d, "ref.sig")
    sp = run([args.spike, "--isa=rv32im_zicsr_zifencei_zicntr", "--priv=m", "--pmpregions=0",
              f"+signature={ref}", "+signature-granularity=4", elf], timeout=300)
    if sp.returncode or not os.path.exists(ref):
        return {"test": name, "status": "ERROR", "msg": "spike failed: " + sp.stderr[-500:]}
    dut = os.path.join(d, "dut.sig")
    p = run([args.bin, f"+elf={elf}", f"+sig={dut}", "+cosim=1", f"+cov={d}/isa.cov",
             f"+vcov={d}/coverage.dat"], timeout=600)
    with open(os.path.join(d, "run.log"), "w") as f:
        f.write(p.stdout + p.stderr)
    if p.returncode or "[tb] PASS" not in p.stdout:
        msg = "\n".join(l for l in p.stdout.splitlines() if "FAIL" in l or "rtl" in l or "spike" in l)
        return {"test": name, "status": "FAIL", "msg": msg[-1200:]}
    r, t = open(ref).read().split(), open(dut).read().split()
    if r != t:
        bad = next((i for i in range(min(len(r), len(t))) if r[i] != t[i]), min(len(r), len(t)))
        return {"test": name, "status": "FAIL",
                "msg": f"signature mismatch at word {bad} (ref {len(r)} words, dut {len(t)} words)"}
    return {"test": name, "status": "PASS", "words": len(r)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--suite", required=True, help="riscv-arch-test checkout (3.9.1)")
    ap.add_argument("--spike", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--rv-prefix", default="riscv64-unknown-elf-")
    args = ap.parse_args()
    base = os.path.join(args.suite, "riscv-test-suite", "rv32i_m")
    if not os.path.isdir(base):
        sys.exit(f"riscv-arch-test not found at {args.suite} (git submodule update --init)")
    work = [(s, os.path.join(base, s, "src", f)) for s in SUITES
            for f in sorted(os.listdir(os.path.join(base, s, "src"))) if f.endswith(".S")]
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        results = list(ex.map(lambda w: one(args, *w), work))
    os.makedirs(args.out, exist_ok=True)
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
        if r["status"] not in ("PASS", "N/A"):
            print(f"{r['status']}: {r['test']}\n  {r.get('msg', '')}")
    ran = sum(v for k, v in counts.items() if k != "N/A")
    summary = {"counts": counts, "applicable": ran, "results": results,
               "pass_rate": counts.get("PASS", 0) / max(1, ran)}
    with open(os.path.join(args.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    for s in SUITES:
        sub = [r for r in results if r["test"].startswith(s + "/")]
        print(f"  {s:10s} " + ", ".join(f"{k}={sum(r['status'] == k for r in sub)}"
                                       for k in ("PASS", "FAIL", "ERROR", "N/A")))
    print(f"ARCHTEST: {counts.get('PASS', 0)}/{ran} applicable tests passed "
          f"({100.0 * summary['pass_rate']:.1f}%), {counts.get('N/A', 0)} not applicable")
    sys.exit(0 if counts.get("PASS", 0) == ran else 1)


if __name__ == "__main__":
    main()
