#!/usr/bin/env python3
"""Check a regression's results against its required-test list (doc/SPEC.md).

Rules (verification rules in doc/SPEC.md):
  * every required test ID must have at least one result, otherwise it was
    missing / not run -> failure
  * a result for an ID that is not in the required list -> "unknown test ID"
    -> failure
  * an ID passes only if every one of its results is PASS; a single FAIL (or
    any other status: ERROR, TIMEOUT, SKIP, ABORTED, ...) fails the ID, and a
    later PASS for the same ID never overwrites it
  * N/A is accepted only for IDs declared "na <id>  # reason" in the required
    list, and such IDs must report N/A (not silently PASS or vanish)

Results file: JSON, a list of {"id": str, "status": str, ...} objects (or an
object with a "results" key holding that list).
Required list: one ID per line ("# comment" allowed); brace ranges such as
"seed{1..200}" expand to seed1 .. seed200; "na <id>  # reason" declares a test
that is not applicable (the reason is mandatory).

Usage: check_results.py --results R.json --required REQ.txt [--name NAME]
Exit status 0 only if every rule holds.
"""
import argparse
import json
import re
import sys


def expand(token):
    m = re.search(r"\{(\d+)\.\.(\d+)\}", token)
    if not m:
        return [token]
    out = []
    for i in range(int(m.group(1)), int(m.group(2)) + 1):
        out += expand(token[:m.start()] + str(i) + token[m.end():])
    return out


def load_required(path):
    req, na, errors = [], {}, []
    for n, line in enumerate(open(path), 1):
        body, _, comment = line.partition("#")
        parts = body.split()
        if not parts:
            continue
        if parts[0] == "na":
            if len(parts) != 2:
                errors.append(f"{path}:{n}: malformed 'na' line")
            elif not comment.strip():
                errors.append(f"{path}:{n}: 'na {parts[1]}' without a reason")
            else:
                for i in expand(parts[1]):
                    na[i] = comment.strip()
            continue
        if len(parts) != 1:
            errors.append(f"{path}:{n}: malformed line {line.strip()!r}")
            continue
        req += expand(parts[0])
    dup = sorted({r for r in req if req.count(r) > 1})
    if dup:
        errors.append(f"{path}: duplicate required IDs {dup[:5]}")
    return req, na, errors


def check(results, required, na):
    """Return (list of failure strings, dict id -> final status)."""
    by_id = {}
    for r in results:
        by_id.setdefault(str(r.get("id")), []).append(str(r.get("status", "")).upper())
    failures, final = [], {}
    for rid, sts in by_id.items():
        if rid not in required and rid not in na:
            failures.append(f"unknown test ID '{rid}' (status {sts})")
            final[rid] = "UNKNOWN"
            continue
        if rid in na:
            ok = all(s == "N/A" for s in sts)
            final[rid] = "N/A" if ok else "FAIL"
            if not ok:
                failures.append(f"'{rid}' is declared not applicable but reported {sts}")
            continue
        bad = [s for s in sts if s != "PASS"]
        final[rid] = "PASS" if not bad else bad[0]
        if bad:
            failures.append(f"'{rid}': {bad[0]}" + (f" (results {sts})" if len(sts) > 1 else ""))
    for rid in required:
        if rid not in by_id:
            failures.append(f"required test '{rid}' missing / not run")
            final[rid] = "MISSING"
    for rid in na:
        if rid not in by_id:
            failures.append(f"not-applicable test '{rid}' did not report N/A (missing)")
    return failures, final


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", required=True)
    ap.add_argument("--required", required=True)
    ap.add_argument("--name", default="")
    a = ap.parse_args()
    name = a.name or a.results
    try:
        data = json.load(open(a.results))
    except (OSError, ValueError) as e:
        print(f"RESULTS {name}: FAIL (cannot read results: {e})")
        return 1
    results = data["results"] if isinstance(data, dict) else data
    required, na, errors = load_required(a.required)
    failures, final = check(results, required, na)
    failures = errors + failures
    npass = sum(1 for v in final.values() if v == "PASS")
    print(f"RESULTS {name}: {npass}/{len(required)} required tests passed, "
          f"{len(na)} declared not applicable, {len(failures)} problem(s)")
    for f in failures[:50]:
        print("  " + f)
    if len(failures) > 50:
        print(f"  ... {len(failures) - 50} more")
    return 1 if failures or not required else 0


if __name__ == "__main__":
    sys.exit(main())
