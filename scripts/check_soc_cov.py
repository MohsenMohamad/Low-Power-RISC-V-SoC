#!/usr/bin/env python3
"""Check the SoC testbench coverage file (sim/tb_soc.sv "COV" lines) against goals.

Coverage file lines: "COV <group> <bin> <count>".
Goals file lines:    "<group> <bin|*> >= N" or "<group> <bin> == N" ("*" = every
                     bin of the group reported in the coverage file).
Waiver file lines:   "<group> <bin>  # reason" (reason mandatory).

Fails (exit 1) when a goal is not met and not waived, when a goal names a bin
that the coverage file does not report (missing data), when the coverage file
has no COV lines, for a waiver without a reason, and for a stale waiver (one
that does not excuse any unmet goal). doc/SPEC.md verification rules: aborted
transitions are reported by the testbench in group "aborted" and are never
counted in "pstate" or "arc" coverage.
"""
import argparse
import re
import sys


def load_cov(path):
    cov = {}
    for line in open(path):
        m = re.match(r"^COV (\S+) (\S+(?: \S+)*?) (\d+)\s*$", line)
        if m:
            cov.setdefault(m.group(1), {})[m.group(2)] = int(m.group(3))
    return cov


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cov", required=True)
    ap.add_argument("--goals", required=True)
    ap.add_argument("--waivers", default="")
    a = ap.parse_args()
    failures, unmet = [], []
    try:
        cov = load_cov(a.cov)
    except OSError as e:
        print(f"SOC-COV {a.cov}: FAIL ({e})")
        return 1
    if not cov:
        failures.append("no COV lines in the coverage file")
    for n, line in enumerate(open(a.goals), 1):
        body = line.split("#", 1)[0].split()
        if not body:
            continue
        if len(body) != 4 or body[2] not in (">=", "=="):
            failures.append(f"{a.goals}:{n}: malformed goal {line.strip()!r}")
            continue
        grp, b, op, val = body[0], body[1], body[2], int(body[3])
        bins = sorted(cov.get(grp, {})) if b == "*" else [b]
        if b == "*" and not bins:
            failures.append(f"goal {grp} *: group not reported")
        for bn in bins:
            if bn not in cov.get(grp, {}):
                failures.append(f"goal {grp} {bn}: bin not reported (missing data)")
                continue
            c = cov[grp][bn]
            if not (c >= val if op == ">=" else c == val):
                unmet.append((grp, bn, f"{c} (goal {op} {val})"))
    waivers = {}
    if a.waivers:
        for n, line in enumerate(open(a.waivers), 1):
            body, _, reason = line.partition("#")
            parts = body.split()
            if not parts:
                continue
            if len(parts) != 2:
                failures.append(f"{a.waivers}:{n}: malformed waiver {line.strip()!r}")
            elif not reason.strip():
                failures.append(f"{a.waivers}:{n}: waiver without a reason {line.strip()!r}")
            else:
                waivers[(parts[0], parts[1])] = reason.strip()
    used = set()
    for grp, bn, got in unmet:
        if (grp, bn) in waivers:
            used.add((grp, bn))
            print(f"  waived: {grp} {bn} = {got}: {waivers[(grp, bn)]}")
        else:
            failures.append(f"coverage goal not met: {grp} {bn} = {got}")
    for w in sorted(set(waivers) - used):
        failures.append(f"stale waiver {w[0]} {w[1]} (goal is met or not a goal of this run)")
    nbins = sum(len(v) for v in cov.values())
    if failures:
        print(f"SOC-COV {a.cov}: FAIL ({nbins} bins reported)")
        for f in failures:
            print("  " + f)
        return 1
    print(f"SOC-COV {a.cov}: PASS ({nbins} bins reported, all goals met, {len(used)} waived)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
