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
"""
import argparse
import collections
import glob
import json
import os
import subprocess

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
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    dats = sorted(glob.glob(os.path.join(a.build, "cosim/regress/**/coverage*.dat"), recursive=True) +
                  glob.glob(os.path.join(a.build, "archtest/*/*/coverage.dat")) +
                  glob.glob(os.path.join(a.build, "cachetest/*/seed*/coverage.dat")))
    # Merged Verilator database (for verilator_coverage --annotate if wanted)
    if dats:
        subprocess.run([a.verilator_coverage, "--write", os.path.join(a.out, "merged.dat")] + dats,
                       capture_output=True)

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
            elif "/rtl/" in f and t in ("line", "toggle", "expr", "branch", "block"):
                o = d.get("o", "")
                if t == "toggle" and os.path.basename(f) == "tech_sram_sp.sv" and o.startswith("mem"):
                    continue   # memory array contents: data-dependent, excluded
                code[(f[f.index("/rtl/") + 1:], t, d.get("l"), d.get("n"), o)] += c

    # ISA bins
    isa = collections.Counter()
    for p in glob.glob(os.path.join(a.build, "**/isa.cov"), recursive=True):
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


if __name__ == "__main__":
    main()
