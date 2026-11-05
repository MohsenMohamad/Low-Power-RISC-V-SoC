#!/usr/bin/env python3
"""Merge coverage from all flows and check it against the coverage plan.

Inputs (whatever exists under --build):
  cosim/regress/seed*/coverage.dat, archtest/**/coverage.dat   (cpu_top)
  cachetest/{dcache,icache}/seed*/coverage.dat                 (cache benches)
  **/isa.cov                                                   (ISA bins from the commit trace)

Reports:
  * functional: ISA plan bins, SVA cover properties, covergroup bins (holes listed)
  * code: line / toggle / expression points per RTL file (union over all flows)
Writes <out>/report.md and <out>/summary.json.

Coverage goals (doc/SPEC.md verification rules): every ISA plan bin, every SVA
cover property and every covergroup bin must be hit. A hole fails the run
(exit 1) unless it is listed with a reason in the waiver file (--waivers,
default dv/coverage_waivers.txt; format "<kind> <bin>  # reason", kind is
isa, cover or cg). A waiver without a reason, or one that matches no hole
(stale), is an error. Missing coverage inputs (no database for one of the
required flows) also fail the run. Code coverage is reported, not gated.
"""
import argparse
import collections
import glob
import json
import os
import subprocess
import sys

REQUIRED_DB_GLOBS = {
    "cosim": "cosim/regress/**/coverage*.dat",
    "archtest": "archtest/*/*/coverage.dat",
    "cachetest-dcache": "cachetest/dcache/seed*/coverage.dat",
    "cachetest-icache": "cachetest/icache/seed*/coverage.dat",
}


def load_waivers(path):
    """Return ({(kind, bin): reason}, [errors])."""
    waivers, errors = {}, []
    if not path or not os.path.exists(path):
        return waivers, errors
    for n, line in enumerate(open(path), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        body, _, reason = line.partition("#")
        parts = body.split()
        if len(parts) != 2 or parts[0] not in ("isa", "cover", "cg"):
            errors.append(f"{path}:{n}: malformed waiver: {line!r}")
            continue
        if not reason.strip():
            errors.append(f"{path}:{n}: waiver without a reason: {line!r}")
            continue
        waivers[(parts[0], parts[1])] = reason.strip()
    return waivers, errors

RV32I = ("lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw addi slti sltiu xori "
         "ori andi slli srli srai add sub sll slt sltu xor srl sra or and fence fence.i").split()
RV32M = "mul mulh mulhsu mulhu div divu rem remu".split()
ZICSR = "csrrw csrrs csrrc csrrwi csrrsi csrrci".split()
SYS = "mret wfi".split()


def isa_plan():
    plan = {}
    for m in RV32I + RV32M + ZICSR + SYS:
        plan[f"insn:{m}"] = "instruction retired"
    for c, n in [(0, "instr misaligned"), (1, "instr access fault"), (2, "illegal"), (3, "breakpoint"),
                 (4, "load misaligned"), (5, "load access fault"), (6, "store misaligned"),
                 (7, "store access fault"), (11, "ecall")]:
        plan[f"trap:{c}"] = n
    for c, n in [(3, "machine software"), (7, "machine timer"), (11, "machine external")]:
        plan[f"irq:{c}"] = n + " interrupt"
    for b in "beq bne blt bge bltu bgeu".split():
        plan[f"br:{b}:taken"] = "branch taken"
        plan[f"br:{b}:nottaken"] = "branch not taken"
    for k in ("ld", "st"):
        for sz, offs in (("b", (0, 1, 2, 3)), ("h", (0, 2)), ("w", (0,))):
            for o in offs:
                plan[f"{k}:{sz}:off{o}"] = "aligned access, byte offset"
    for v in ("zero", "minus1", "intmin"):
        plan[f"val:{v}"] = "result corner value"
    for r in range(1, 32):
        plan[f"rd:x{r}"] = "destination register"
    return plan


def parse_dat(path):
    recs = []
    with open(path, errors="replace") as f:
        for line in f:
            if not line.startswith("C '"):
                continue
            key, cnt = line[3:].rsplit("' ", 1)
            d = {}
            for part in key.split("\x01"):
                if "\x02" in part:
                    k, v = part.split("\x02", 1)
                    d[k] = v
            recs.append((d, int(cnt)))
    return recs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build", default="build")
    ap.add_argument("--out", default="build/coverage")
    ap.add_argument("--verilator-coverage", default="verilator_coverage")
    ap.add_argument("--waivers", default=os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "dv/coverage_waivers.txt"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    failures = []
    for flow, g in REQUIRED_DB_GLOBS.items():
        if not glob.glob(os.path.join(a.build, g), recursive=True):
            failures.append(f"no coverage database for required flow '{flow}' ({g})")

    dats = sorted(glob.glob(os.path.join(a.build, "cosim/regress/**/coverage*.dat"), recursive=True) +
                  glob.glob(os.path.join(a.build, "archtest/*/*/coverage.dat")) +
                  glob.glob(os.path.join(a.build, "cachetest/*/seed*/coverage.dat")))
    # Merged Verilator database (for verilator_coverage --annotate if wanted)
    if dats:
        p = subprocess.run([a.verilator_coverage, "--write", os.path.join(a.out, "merged.dat")] + dats,
                           capture_output=True, text=True)
        if p.returncode:
            failures.append("verilator_coverage merge failed: " + p.stderr[-300:])

    code = collections.defaultdict(int)          # (file,type,line,col,o) -> count
    user = collections.defaultdict(int)          # cover property name -> count
    cgbins = collections.defaultdict(int)        # covergroup bin -> count
    for p in dats:
        for d, c in parse_dat(p):
            t = d.get("t", "")
            f = d.get("f", "")
            if t == "user":
                user[(os.path.basename(f), d.get("o", d.get("h", "?")))] += c
            elif t == "covergroup":
                h = d.get("h", "?")
                cgbins[(os.path.basename(f), h)] += c
            elif ("/rtl/" in f or f.startswith("rtl/")) and t in ("line", "toggle", "expr", "branch", "block"):
                if f.startswith("rtl/"):
                    f = "/" + f
                o = d.get("o", "")
                if t == "toggle" and os.path.basename(f) == "tech_sram_sp.sv" and o.startswith("mem"):
                    continue   # memory array contents: data-dependent, excluded
                code[(f[f.index("/rtl/") + 1:], t, d.get("l"), d.get("n"), o)] += c

    # ISA bins
    isa = collections.Counter()
    isa_files = glob.glob(os.path.join(a.build, "cosim/**/isa.cov"), recursive=True) + \
        glob.glob(os.path.join(a.build, "archtest/**/isa.cov"), recursive=True)
    if not isa_files:
        failures.append("no ISA coverage (isa.cov) files")
    for p in isa_files:
        for line in open(p):
            k, v = line.rsplit(" ", 1)
            isa[k] += int(v)
    plan = isa_plan()
    isa_hit = {k: isa.get(k, 0) for k in plan}
    isa_holes = [k for k, v in isa_hit.items() if v == 0]

    # Code coverage summary
    per_file = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
    for (f, t, *_), c in code.items():
        per_file[f][t][1] += 1
        per_file[f][t][0] += int(c > 0)
    totals = collections.defaultdict(lambda: [0, 0])
    for f in per_file:
        for t, (h, n) in per_file[f].items():
            totals[t][0] += h
            totals[t][1] += n

    user_holes = sorted(k for k, v in user.items() if v == 0)
    cg_holes = sorted(k for k, v in cgbins.items() if v == 0)

    def pct(h, n):
        return 100.0 * h / n if n else 0.0

    md = ["# Coverage report", "",
          f"Merged {len(dats)} Verilator coverage databases and the ISA commit-trace bins.", ""]
    md += ["## Functional coverage", "",
           "| Group | Covered | Total | % |", "|---|---|---|---|",
           f"| ISA plan bins (commit trace) | {len(plan) - len(isa_holes)} | {len(plan)} | "
           f"{pct(len(plan) - len(isa_holes), len(plan)):.1f} |",
           f"| SVA cover properties | {len(user) - len(user_holes)} | {len(user)} | "
           f"{pct(len(user) - len(user_holes), len(user)):.1f} |",
           f"| Covergroup bins | {len(cgbins) - len(cg_holes)} | {len(cgbins)} | "
           f"{pct(len(cgbins) - len(cg_holes), len(cgbins)):.1f} |", ""]
    md += ["### Holes", ""]
    md += [f"- ISA: `{h}` ({plan[h]})" for h in isa_holes] or ["- ISA: none"]
    md += [f"- cover property: `{n}` ({f})" for f, n in user_holes] or ["- cover properties: none"]
    md += [f"- covergroup bin: `{n}` ({f})" for f, n in cg_holes] or ["- covergroup bins: none"]
    md += ["", "### Cover properties", "", "| File | Property | Hits |", "|---|---|---|"]
    md += [f"| {f} | {n} | {c} |" for (f, n), c in sorted(user.items())]
    md += ["", "### Covergroup bins", "", "| File | Bin | Hits |", "|---|---|---|"]
    md += [f"| {f} | {n} | {c} |" for (f, n), c in sorted(cgbins.items())]
    md += ["", "### ISA bins", "", "| Bin | Hits |", "|---|---|"]
    md += [f"| {k} | {v} |" for k, v in sorted(isa_hit.items())]
    md += ["", "## Code coverage (RTL, union of all flows)", "",
           "| File | Line | Toggle | Expression |", "|---|---|---|---|"]
    for f in sorted(per_file):
        cells = []
        for t in ("line", "toggle", "expr"):
            h, n = per_file[f].get(t, [0, 0])
            cells.append(f"{h}/{n} ({pct(h, n):.1f}%)" if n else "-")
        md.append(f"| {f} | " + " | ".join(cells) + " |")
    cells = [f"{totals[t][0]}/{totals[t][1]} ({pct(*totals[t]):.1f}%)" for t in ("line", "toggle", "expr")]
    md.append("| **total** | " + " | ".join(cells) + " |")
    md += ["", "Toggle coverage excludes the contents of SRAM model arrays (`tech_sram_sp.mem`).", ""]
    uncovered_lines = sorted((f, int(l)) for (f, t, l, n, o), c in code.items() if t == "line" and c == 0)
    if uncovered_lines:
        md += ["### Uncovered line points", ""]
        md += [f"- {f}:{l}" for f, l in uncovered_lines]
    open(os.path.join(a.out, "report.md"), "w").write("\n".join(md) + "\n")

    summary = {
        "databases": len(dats),
        "isa": {"covered": len(plan) - len(isa_holes), "total": len(plan), "holes": isa_holes},
        "cover_properties": {"covered": len(user) - len(user_holes), "total": len(user),
                             "holes": [n for _, n in user_holes]},
        "covergroup_bins": {"covered": len(cgbins) - len(cg_holes), "total": len(cgbins),
                            "holes": [n for _, n in cg_holes]},
        "code": {t: {"covered": h, "total": n, "pct": round(pct(h, n), 1)} for t, (h, n) in totals.items()},
    }
    json.dump(summary, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    print(f"COVERAGE: ISA {summary['isa']['covered']}/{summary['isa']['total']}, "
          f"cover properties {summary['cover_properties']['covered']}/{summary['cover_properties']['total']}, "
          f"covergroup bins {summary['covergroup_bins']['covered']}/{summary['covergroup_bins']['total']}, "
          + ", ".join(f"{t} {v['pct']}%" for t, v in sorted(summary["code"].items())))
    if isa_holes or user_holes or cg_holes:
        print("  holes: " + ", ".join(isa_holes + [n for _, n in user_holes] + [n for _, n in cg_holes]))
    print(f"  report: {os.path.join(a.out, 'report.md')}")

    waivers, werr = load_waivers(a.waivers)
    failures += werr
    holes = [("isa", h) for h in isa_holes] + [("cover", n) for _, n in user_holes] + \
            [("cg", n) for _, n in cg_holes]
    used = set()
    for h in holes:
        if h in waivers:
            used.add(h)
            print(f"  waived hole {h[0]} {h[1]}: {waivers[h]}")
        else:
            failures.append(f"coverage hole {h[0]} {h[1]} (not waived)")
    for w in sorted(set(waivers) - used):
        failures.append(f"stale waiver {w[0]} {w[1]}: no such hole")
    summary["waived"] = [f"{k} {b}" for k, b in sorted(used)]
    summary["failures"] = failures
    json.dump(summary, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    if failures:
        print("COVERAGE: FAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("COVERAGE: PASS (all coverage goals met)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
