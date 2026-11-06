#!/usr/bin/env python3
"""Failure triage for tools/regress.py results.

  triage.py [build/regress]                 group failures by signature
  triage.py --db build/triage/seeds.json    failing-seed database (kept across runs)
  triage.py --replay <seed>                 rerun a failing test with its seed and
                                            compare the new signature with the stored one
  triage.py --replay-sig <id>               replay one seed of signature group <id>

Signature: (reason, exception cause, PC, last power state, watchdog) taken
from the crash dump (tools/dbg_decode.py) of the failing run; without a
dump: TIMEOUT, or the first error line with numbers masked.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbg_decode  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ERR_RE = re.compile(r"(%Error.*|%Fatal.*|.*CHECK FAILED.*|.*SIM RESULT: FAIL.*|.*TEST FAILED.*|.*Assertion failed.*)")


def texts_of(t):
    out = []
    if t.get("artifacts") and t.get("seed") is not None:
        for ext in (".uart", ".log"):
            p = os.path.join(t["artifacts"], "%s_s%d%s" % (t["name"], t["seed"], ext))
            if os.path.isfile(p):
                out.append((p, open(p, errors="replace").read()))
    if t.get("log") and os.path.isfile(t["log"]):
        out.append((t["log"], open(t["log"], errors="replace").read()))
    return out


def classify(t):
    """Return (signature dict, source description)."""
    for path, text in texts_of(t):
        try:
            dumps = dbg_decode.parse_dumps(text)
        except dbg_decode.DumpError:
            dumps = []
        dumps = [d for d in dumps if d["crc_ok"] and d["reason"] != "request"]
        if dumps:
            sig = dbg_decode.signature(dumps[-1])
            sig["cause"] = "0x%x" % sig["cause"]
            sig["pc"] = "0x%08x" % sig["pc"]
            return sig, path
    if t["status"] == "TIMEOUT":
        return {"reason": "timeout"}, t.get("log")
    for path, text in texts_of(t):
        m = ERR_RE.search(text)
        if m:
            line = re.sub(r"0x[0-9a-fA-F]+|\d+", "N", m.group(1).strip())[:100]
            return {"reason": "error", "message": line}, path
        # step tables of other areas' runners: "<step name>   FAIL  ..."
        steps = re.findall(r"^\s*(\S.*?)\s{2,}FAIL\b", text, re.M)
        if steps:
            return {"reason": "error", "message": "failing step(s): " + "; ".join(sorted(set(steps)))}, path
    return {"reason": "unknown", "detail": t.get("detail", "")}, t.get("log")


def sig_id(sig):
    return hashlib.sha1(json.dumps(sig, sort_keys=True).encode()).hexdigest()[:8]


def load_db(path):
    if os.path.isfile(path):
        return json.load(open(path))
    return {"failures": []}


def replay(entry, timeout):
    """Rerun the stored command of one failing test; return its new signature."""
    t = dict(entry)
    t["log"] = os.path.join(ROOT, "build", "triage", "replay_%s_s%s.log" % (t["name"], t["seed"]))
    os.makedirs(os.path.dirname(t["log"]), exist_ok=True)
    print("replay: %s seed %s\n  $ %s" % (t["name"], t["seed"], " ".join(t["cmd"])))
    t0 = time.time()
    with open(t["log"], "w") as f:
        try:
            rc = subprocess.run(t["cmd"], cwd=t.get("cwd", ROOT), stdout=f, stderr=subprocess.STDOUT,
                                timeout=timeout).returncode
            t["status"] = "PASS" if rc == 0 else "FAIL"
        except subprocess.TimeoutExpired:
            t["status"] = "TIMEOUT"
    sig, src = classify(t) if t["status"] != "PASS" else ({"reason": "pass"}, t["log"])
    print("  result %s in %.0f s, signature %s %s" % (t["status"], time.time() - t0, sig_id(sig), json.dumps(sig)))
    return t["status"], sig


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="?", default=os.path.join(ROOT, "build", "regress"))
    ap.add_argument("--db", default=os.path.join(ROOT, "build", "triage", "failing_seeds.json"))
    ap.add_argument("--replay", type=lambda s: int(s, 0), help="seed to replay")
    ap.add_argument("--replay-sig", help="signature id: replay its first seed")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args(argv)
    db = load_db(a.db)

    if a.replay is not None or a.replay_sig:
        cands = [f for f in db["failures"] if (a.replay is not None and f["seed"] == a.replay) or
                 (a.replay_sig and f["sig_id"] == a.replay_sig)]
        if not cands:
            print("no stored failure for %s (database %s)" % (a.replay if a.replay is not None else a.replay_sig, a.db))
            return 1
        f = cands[0]
        status, sig = replay(f, a.timeout)
        same = sig_id(sig) == f["sig_id"]
        print("REPLAY %s: stored signature %s, new %s -> %s" % (
            f["seed"], f["sig_id"], sig_id(sig), "REPRODUCED" if same else
            ("PASSES NOW" if status == "PASS" else "DIFFERENT FAILURE")))
        return 0 if same else 2

    res = json.load(open(os.path.join(a.results, "results.json")))
    failed = [t for t in res["tests"] if t["status"] in ("FAIL", "TIMEOUT")]
    groups = {}
    for t in failed:
        sig, src = classify(t)
        sid = sig_id(sig)
        g = groups.setdefault(sid, {"sig": sig, "tests": []})
        g["tests"].append((t, src))
        rec = {"sig_id": sid, "signature": sig, "suite": t["suite"], "name": t["name"], "seed": t["seed"],
               "cmd": t["cmd"], "cwd": t["cwd"], "artifacts": t.get("artifacts"), "evidence": src,
               "first_seen": time.strftime("%Y-%m-%d %H:%M:%S")}
        if not any(f["sig_id"] == sid and f["seed"] == t["seed"] and f["name"] == t["name"] for f in db["failures"]):
            db["failures"].append(rec)
    os.makedirs(os.path.dirname(a.db), exist_ok=True)
    json.dump(db, open(a.db, "w"), indent=1)

    total = len(res["tests"])
    print("Triage of %s: %d tests, %d failing, %d signature group(s)" % (a.results, total, len(failed), len(groups)))
    if not groups:
        return 0
    print("%-8s %5s  %-60s %s" % ("SIG", "COUNT", "SIGNATURE", "SEEDS"))
    for sid, g in sorted(groups.items(), key=lambda kv: -len(kv[1]["tests"])):
        s = g["sig"]
        if s.get("reason") in ("error", "unknown"):
            desc = "%s: %s" % (s["reason"], s.get("message", s.get("detail", "")))
        elif s.get("reason") == "timeout":
            desc = "timeout (no crash dump)"
        else:
            desc = "%s cause=%s pc=%s pstate=%s%s" % (s["reason"], s["cause"], s["pc"], s["pstate"],
                                                       " watchdog" if s.get("watchdog") else "")
        seeds = ",".join(str(t["seed"]) for t, _ in g["tests"])
        print("%-8s %5d  %-60s %s" % (sid, len(g["tests"]), desc[:60], seeds))
        t0, src = g["tests"][0]
        print("         example: %s seed %s, evidence %s" % (t0["name"], t0["seed"], os.path.relpath(src, ROOT) if src else "-"))
        print("         replay:  tools/triage.py --replay %s" % t0["seed"])
    print("failing seeds stored in %s (%d entries)" % (os.path.relpath(a.db, ROOT), len(db["failures"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
