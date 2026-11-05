#!/usr/bin/env python3
"""Merge coverage from every run into one report.

  cov_merge.py [--out DIR] <dir or file>...

Collected inputs (searched recursively):
  *.dat    Verilator coverage (line / toggle / branch / cover properties);
           points are merged per source location, so the same RTL line or
           cover property hit by different testbenches counts once
  *.info   lcov data (e.g. other areas' tools), summarised per file
  *.uart / *.log   functional coverage lines printed by firmware:
           "COV <key>=<value> ... n=<count>"  (stress test op mix and
           power-state x operating-point matrix)

Outputs in DIR: report.txt, report.json, merged.dat and coverage.info
(when verilator_coverage is available).
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COV_LINE_RE = re.compile(r"^COV ((?:\w+=\S+ )+)n=(\d+)\s*$", re.M)


def parse_dat(path, points):
    with open(path, errors="replace") as f:
        for line in f:
            if not line.startswith("C '"):
                continue
            q = line.rfind("'")
            key, cnt = line[3:q], int(line[q + 1:].strip() or 0)
            fields = dict(kv.split("\x02", 1) for kv in key.split("\x01") if "\x02" in kv)
            fname = fields.get("f", "?")
            if not os.path.isabs(fname):
                fname = os.path.normpath(os.path.join(ROOT, "verif", "debug", fname))
            k = (os.path.relpath(fname, ROOT), int(fields.get("l", 0)), fields.get("n", ""),
                 fields.get("t", fields.get("page", "?").split("/")[0].replace("v_", "")), fields.get("o", ""))
            points[k] += cnt


def find(paths, exts):
    for p in paths:
        if os.path.isfile(p):
            if p.endswith(exts):
                yield p
            continue
        for d, _dirs, files in os.walk(p):
            for fn in files:
                if fn.endswith(exts):
                    yield os.path.join(d, fn)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "coverage"))
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)

    dats = sorted(set(find(a.paths, (".dat",))))
    dats = [d for d in dats if open(d, errors="replace").read(32).startswith("# SystemC::Coverage")]
    points = collections.Counter()
    for d in dats:
        parse_dat(d, points)

    # ---- code coverage per RTL file and type ----
    per = collections.defaultdict(lambda: [0, 0])
    for (f, _l, _n, t, _o), c in points.items():
        if t == "user" or not f.startswith("rtl" + os.sep):
            continue
        per[(f, t)][1] += 1
        per[(f, t)][0] += c > 0
    tot = collections.defaultdict(lambda: [0, 0])
    for (f, t), (h, n) in per.items():
        tot[t][0] += h
        tot[t][1] += n
    # ---- cover properties ----
    user = {}
    for (f, l, _n, t, o), c in points.items():
        if t == "user":
            k = "%s:%d %s" % (f, l, o)
            user[k] = user.get(k, 0) + c

    # ---- firmware functional coverage ----
    func = collections.Counter()
    for p in find(a.paths, (".uart", ".log")):
        # the simulation log repeats the UART output: count each run once
        if p.endswith(".log") and os.path.isfile(p[:-4] + ".uart"):
            continue
        try:
            text = open(p, errors="replace").read()
        except OSError:
            continue
        for m in COV_LINE_RE.finditer(text.replace("\r", "")):
            func[m.group(1).strip()] += int(m.group(2))

    # ---- lcov inputs (other areas) ----
    lcov = {}
    n_lcov = 0
    for p in find(a.paths, (".info",)):
        if os.path.abspath(p).startswith(os.path.abspath(a.out)):
            continue
        cur = None
        n_lcov += 1
        for line in open(p, errors="replace"):
            if line.startswith("SF:"):
                cur = line[3:].strip()
                lcov.setdefault(cur, [0, 0])
            elif line.startswith("DA:") and cur:
                hits = int(line.split(",")[1])
                lcov[cur][1] += 1
                lcov[cur][0] += hits > 0

    out = []
    w = out.append
    w("Coverage report: %d Verilator coverage files, %d lcov files" % (len(dats), n_lcov))
    w("")
    w("RTL code coverage (rtl/, merged over all testbenches)")
    w("  %-40s %-8s %8s" % ("file", "type", "covered"))
    for (f, t) in sorted(per):
        h, n = per[(f, t)]
        w("  %-40s %-8s %5.1f%%  (%d/%d)" % (f, t, 100.0 * h / max(n, 1), h, n))
    for t, (h, n) in sorted(tot.items()):
        w("  %-40s %-8s %5.1f%%  (%d/%d)" % ("TOTAL", t, 100.0 * h / max(n, 1), h, n))
    w("")
    hit = sum(1 for v in user.values() if v > 0)
    w("Cover properties: %d of %d hit" % (hit, len(user)))
    for k in sorted(user, key=lambda k: (user[k] > 0, k)):
        w("  %-8s %s" % (user[k] if user[k] else "MISSED", k))
    if func:
        w("")
        w("Firmware functional coverage (stress tests, summed over seeds)")
        for k in sorted(func):
            w("  %-8s %s" % (func[k] if func[k] else "MISSED", k))
    if lcov:
        w("")
        w("lcov line coverage")
        for f, (h, n) in sorted(lcov.items()):
            w("  %-60s %5.1f%% (%d/%d)" % (f, 100.0 * h / max(n, 1), h, n))
    report = "\n".join(out)
    print(report)
    open(os.path.join(a.out, "report.txt"), "w").write(report + "\n")
    json.dump({"files": len(dats), "code": {"%s|%s" % k: v for k, v in per.items()},
               "totals": dict(tot), "cover_properties": user, "functional": dict(func),
               "lcov": lcov}, open(os.path.join(a.out, "report.json"), "w"), indent=1)

    vc = shutil.which("verilator_coverage")
    if vc and dats:
        subprocess.run([vc, "--write", os.path.join(a.out, "merged.dat")] + dats, check=False,
                       stdout=subprocess.DEVNULL)
        subprocess.run([vc, "--write-info", os.path.join(a.out, "coverage.info"), os.path.join(a.out, "merged.dat")],
                       check=False, stdout=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
