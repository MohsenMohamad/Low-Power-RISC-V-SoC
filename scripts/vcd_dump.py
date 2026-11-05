#!/usr/bin/env python3
"""Print selected signals of a (small) VCD trace as a table, one row per time.

Usage: vcd_dump.py trace.vcd [substring ...]
"""
import sys


def main():
    path, pats = sys.argv[1], sys.argv[2:]
    ids, scope, vals, rows, t = {}, [], {}, [], None
    for line in open(path):
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "$scope":
            scope.append(tok[2])
        elif tok[0] == "$upscope":
            scope.pop()
        elif tok[0] == "$var":
            name = ".".join(scope[1:] + [tok[4]])
            if not pats or any(p in name for p in pats):
                ids.setdefault(tok[3], []).append(name)
        elif tok[0].startswith("#"):
            if t is not None:
                rows.append((t, dict(vals)))
            t = int(tok[0][1:])
        elif tok[0][0] in "01xz" and tok[0][1:] in ids:
            for n in ids[tok[0][1:]]:
                vals[n] = tok[0][0]
        elif tok[0][0] == "b" and len(tok) > 1 and tok[1] in ids:
            for n in ids[tok[1]]:
                vals[n] = tok[0][1:]
    if t is not None:
        rows.append((t, dict(vals)))
    names = sorted({n for v in ids.values() for n in v})
    for n in names:
        print(f"{n[-40:]:>40} " + " ".join(f"{r[1].get(n, '-'):>4}" for r in rows))


if __name__ == "__main__":
    main()
