#!/usr/bin/env python3
"""Random-stream regression: generate programs, run them in lockstep with Spike.

Each seed gets its own stimulus configuration (AXI back-pressure, latency,
interrupt rate, direct/vectored mtvec). Results are written to
<out>/summary.json and failing seeds are listed with the mismatch message.
"""
import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def config(seed):
    ready = [100, 100, 80, 50][seed % 4]
    lat = [0, 2, 5, 0][(seed // 4) % 4]
    irq = [0, 5, 20, 60][(seed // 16) % 4]
    return {"ready_pct": ready, "max_lat": lat, "irq_rate": irq}


def run_one(args, seed):
    d = os.path.join(args.out, f"seed{seed}")
    os.makedirs(d, exist_ok=True)
    asm, elf = os.path.join(d, "test.S"), os.path.join(d, "test.elf")
    subprocess.run([sys.executable, os.path.join(ROOT, "dv/cosim/gen_rand.py"), "--seed", str(seed),
                    "--length", str(args.length), "-o", asm], check=True)
    cc = subprocess.run([args.rv_prefix + "gcc", "-march=rv32im_zicsr_zifencei", "-mabi=ilp32",
                         "-nostdlib", "-nostartfiles", "-Wl,--no-warn-rwx-segments",
                         "-T", os.path.join(ROOT, "sw/common/link.ld"), asm, "-o", elf],
                        capture_output=True, text=True)
    if cc.returncode:
        return seed, False, "assembler error: " + cc.stderr[-500:], {}
    cfg = config(seed)
    cmd = [args.bin, f"+elf={elf}", f"+seed={seed}", "+memcmp=1", f"+cov={d}/isa.cov",
           f"+vcov={d}/coverage.dat"] + [f"+{k}={v}" for k, v in cfg.items()]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
        out = p.stdout + p.stderr
        ok = p.returncode == 0 and "[tb] PASS" in out
    except subprocess.TimeoutExpired:
        ok, out = False, "wall-clock timeout"
    with open(os.path.join(d, "run.log"), "w") as f:
        f.write(" ".join(cmd) + "\n" + out)
    stats = {}
    for line in out.splitlines():
        if line.startswith("[tb] cycles="):
            stats = dict(kv.split("=") for kv in line[5:].split())
    msg = next((l for l in out.splitlines() if "FAIL" in l or "MISMATCH" in l), "")
    if not ok:
        msg = "\n".join(l for l in out.splitlines() if not l.startswith("[tb] cycles"))[-1500:]
    return seed, ok, msg, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--seeds", type=int, default=100)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--length", type=int, default=3000)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rv-prefix", default="riscv64-unknown-elf-")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    seeds = range(args.first_seed, args.first_seed + args.seeds)
    results = []
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        for seed, ok, msg, stats in ex.map(lambda s: run_one(args, s), seeds):
            results.append({"seed": seed, "pass": ok, "msg": msg, "config": config(seed), **stats})
            if not ok:
                print(f"seed {seed}: FAIL\n{msg}\n")
    npass = sum(r["pass"] for r in results)
    tot = {k: sum(int(r.get(k, 0)) for r in results) for k in ("retired", "traps", "irqs", "cycles")}
    summary = {"seeds": len(results), "pass": npass, "fail": len(results) - npass,
               "pass_rate": npass / max(1, len(results)), "totals": tot,
               "failing_seeds": [r["seed"] for r in results if not r["pass"]], "results": results}
    with open(os.path.join(args.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"COSIM: {npass}/{len(results)} seeds passed ({100.0 * summary['pass_rate']:.1f}%), "
          f"{tot['retired']} instructions retired, {tot['traps']} exceptions, {tot['irqs']} interrupts "
          f"compared against Spike")
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
