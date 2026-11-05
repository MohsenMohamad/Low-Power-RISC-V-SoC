#!/usr/bin/env python3
"""Convert a validation-suite console log into a results file for the stage-1
result checker (scripts/check_results.py). There is deliberately no second
pass/fail judgement here: every rule (required tests present, unknown test IDs,
a FAIL is never overwritten by a later PASS, SKIP only where declared
not applicable) is applied by check_results.py against a required-test list.

One result per line of the log, in order, nothing merged:
  "[TEST  42] name  PASS|FAIL|SKIP ..."  -> {"id": "<prefix>/42", "status": PASS|FAIL|N/A}
                                            (SKIP becomes N/A: allowed only for
                                            IDs declared "na" in the required list)
  "SUITE RESULT: PASS|FAIL"              -> {"id": "<prefix>/suite-result", ...}
  last line "PASS" / "FAIL ..."          -> {"id": "<prefix>/exit", ...}
                                            (the platform exit line)

Usage: fw_results.py --log LOG --out RESULTS.json [--prefix fw]
Exit status 1 if the log cannot be read; otherwise 0 (the verdict is the
checker's).
"""
import argparse
import json
import re
import sys

TEST_RE = re.compile(r"^\[TEST +(\d+)\] +(\S+) +(PASS|FAIL|SKIP)\b")
SUITE_RE = re.compile(r"^SUITE RESULT: (PASS|FAIL)\b")
EXIT_RE = re.compile(r"^(PASS|FAIL)( 0x[0-9a-fA-F]+)?$")
# the SoC bench prefixes every UART line with "[uart] "
STRIP_RE = re.compile(r"^\[uart\] ?")


def convert(text, prefix):
    results = []
    exit_status = None
    for raw in text.replace("\r", "").splitlines():
        line = STRIP_RE.sub("", raw)
        m = TEST_RE.match(line)
        if m:
            st = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "N/A"}[m.group(3)]
            results.append({"id": f"{prefix}/{int(m.group(1))}", "name": m.group(2), "status": st})
            continue
        m = SUITE_RE.match(line)
        if m:
            results.append({"id": f"{prefix}/suite-result", "status": m.group(1)})
            continue
        m = EXIT_RE.match(line.strip())
        if m:
            exit_status = m.group(1)
    if exit_status is not None:
        results.append({"id": f"{prefix}/exit", "status": exit_status})
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", default="fw")
    a = ap.parse_args()
    try:
        text = open(a.log, errors="replace").read()
    except OSError as e:
        print(f"fw_results: cannot read {a.log}: {e}")
        return 1
    res = convert(text, a.prefix)
    json.dump(res, open(a.out, "w"), indent=1)
    print(f"fw_results: {len(res)} results from {a.log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
