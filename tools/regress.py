#!/usr/bin/env python3
"""Regression runner: discovers and runs every area's tests through their own
Makefiles / scripts, plus N random stress seeds, in parallel with a timeout
per test, and prints a summary table.

  tools/regress.py                       all suites, 4 stress seeds
  tools/regress.py --seeds 20 -j 8       20 stress seeds, 8 jobs
  tools/regress.py --only debug-sv       suites whose name matches
  tools/regress.py --list                show discovered suites / tests
  tools/regress.py --stress-flags 1      stress with fault injection

Outputs (default build/regress/): summary.txt, results.json (input of
tools/triage.py), junit.xml, logs/, artifacts/, coverage/ (tools/cov_merge.py).
Statuses: PASS, FAIL, TIMEOUT, SKIP (tool or area missing; never counted as PASS).
"""
import argparse
import concurrent.futures as cf
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAIL_RE = re.compile(r"^\s*(%Error|%Fatal|.*\bTEST FAILED\b|.*\bSIM RESULT: FAIL\b|.*\bCHECK FAILED\b|"
                     r".*Assertion failed|Traceback \(most recent call last\))", re.M)
SKIP_RE = re.compile(r"^SKIP\b", re.M)


class Test:
    def __init__(self, suite, name, cmd, cwd, timeout, seed=None, pass_regex=None, artifacts=None):
        self.suite, self.name, self.cmd, self.cwd = suite, name, cmd, cwd
        self.timeout, self.seed, self.pass_regex = timeout, seed, pass_regex
        self.artifacts = artifacts
        self.status, self.runtime, self.detail, self.log = "NOTRUN", 0.0, "", ""

    @property
    def key(self):
        return "%s__%s%s" % (self.suite, self.name, "" if self.seed is None else "__s%d" % self.seed)


def make_has_target(d, target):
    mk = os.path.join(d, "Makefile")
    if not os.path.isfile(mk):
        return False
    return re.search(r"^%s\s*:" % re.escape(target), open(mk, errors="replace").read(), re.M) is not None


def is_cocotb(d):
    mk = os.path.join(d, "Makefile")
    return os.path.isfile(mk) and "cocotb-config" in open(mk, errors="replace").read()


def list_tests(d):
    p = subprocess.run(["make", "--no-print-directory", "-C", d, "list-tests"], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("make list-tests failed in %s: %s" % (d, p.stderr.strip()[-200:]))
    return [t.strip() for t in p.stdout.splitlines() if t.strip()]


def discover(cfg):
    """Suites not configured explicitly: walk the roots for Makefiles."""
    disc = cfg.get("discover", {})
    excl = [os.path.join(ROOT, e) for e in disc.get("exclude", [])] + [os.path.join(ROOT, "verif", "uvm")]
    found = []
    for r in disc.get("roots", []):
        base = os.path.join(ROOT, r)
        if not os.path.isdir(base):
            continue
        for d, dirs, _files in os.walk(base):
            if any(d == e or d.startswith(e + os.sep) for e in excl):
                dirs[:] = []
                continue
            dirs[:] = [x for x in dirs if not x.startswith((".", "__", "build", "sim_build"))]
            rel = os.path.relpath(d, ROOT)
            if make_has_target(d, "list-tests"):
                found.append({"name": rel.replace(os.sep, "-"), "kind": "make-list", "dir": rel, "timeout": 900})
                dirs[:] = []
            elif is_cocotb(d):
                found.append({"name": rel.replace(os.sep, "-"), "kind": "cocotb", "dir": rel, "timeout": 900})
                dirs[:] = []
            elif make_has_target(d, "test"):
                found.append({"name": rel.replace(os.sep, "-"), "kind": "make-test", "dir": rel, "timeout": 1800})
                dirs[:] = []
    return found


def expand(suite, args, out):
    """Turn a suite into Test objects (and an optional build command)."""
    kind, name = suite["kind"], suite["name"]
    timeout = args.timeout or suite.get("timeout", 900)
    d = os.path.join(ROOT, suite.get("dir", "."))
    art = os.path.join(out, "artifacts", name)
    tests, build = [], None
    for n in suite.get("needs", []):
        if not os.path.exists(os.path.join(ROOT, n)):
            t = Test(name, "(suite)", [], ROOT, 0)
            t.status, t.detail = "SKIP", "%s not present on this branch" % n
            return [t], None
    if kind == "make-list":
        if suite.get("build"):
            build = ["make", "--no-print-directory", "-C", d, suite["build"]]
        for t in list_tests(d):
            if t in suite.get("exclude", []):
                continue
            for s in suite.get("seeds", [1]):
                tests.append(Test(name, t, ["make", "--no-print-directory", "-C", d, "run-test", "TEST=" + t,
                                            "SEED=%d" % s, "OUT=" + art], ROOT, timeout, s, artifacts=art))
    elif kind == "make-test":
        tests.append(Test(name, "test", ["make", "--no-print-directory", "-C", d, "test"], ROOT, timeout))
    elif kind == "cocotb":
        tests.append(Test(name, "cocotb", ["make", "--no-print-directory", "-C", d, "SIM=verilator"], ROOT, timeout,
                          artifacts=d))
    elif kind == "script":
        tests.append(Test(name, os.path.basename(suite["cmd"][-1]), suite["cmd"], ROOT, timeout,
                          pass_regex=suite.get("pass_regex")))
    elif kind == "stress":
        rnd = random.Random(args.seed_base)
        seeds = args.seed_list or [rnd.randrange(1, 2**31) for _ in range(args.seeds)]
        if suite.get("build"):
            build = ["make", "--no-print-directory", "-C", d, suite["build"]]
        for s in seeds:
            cmd = ["make", "--no-print-directory", "-C", d, "run-test", "TEST=" + suite["test"], "SEED=%d" % s,
                   "OUT=" + art, "ITER=%d" % args.stress_iters, "FLAGS=%d" % args.stress_flags]
            tests.append(Test(name, suite["test"], cmd, ROOT, timeout, s, artifacts=art))
    return tests, build


def run_one(t, logdir):
    t.log = os.path.join(logdir, t.key + ".log")
    t0 = time.time()
    with open(t.log, "w") as f:
        f.write("$ %s\n" % " ".join(t.cmd))
        f.flush()
        p = subprocess.Popen(t.cmd, cwd=t.cwd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = p.wait(timeout=t.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            rc = None
    t.runtime = time.time() - t0
    text = open(t.log, errors="replace").read()
    # simulator / firmware logs written by the test (artifacts dir)
    if t.artifacts and t.seed is not None:
        for ext in (".log", ".uart"):
            pth = os.path.join(t.artifacts, "%s_s%d%s" % (t.name, t.seed, ext))
            if os.path.isfile(pth):
                text += "\n" + open(pth, errors="replace").read()
    m = FAIL_RE.search(text)
    if rc is None:
        t.status, t.detail = "TIMEOUT", "killed after %d s" % t.timeout
    elif rc == 0 and SKIP_RE.search(text) and not m:
        t.status, t.detail = "SKIP", SKIP_RE.search(text) and text[SKIP_RE.search(text).start():].splitlines()[0]
    elif rc == 0 and not m and (t.pass_regex is None or re.search(t.pass_regex, text)):
        t.status = "PASS"
    else:
        t.status = "FAIL"
        if m:
            t.detail = text[m.start():].splitlines()[0].strip()[:120]
        elif rc != 0:
            t.detail = "exit code %d" % rc
        else:
            t.detail = "pass pattern not found"
    return t


def junit(tests, path):
    with open(path, "w") as f:
        f.write('<?xml version="1.0"?>\n<testsuites>\n')
        for s in sorted({t.suite for t in tests}):
            ts = [t for t in tests if t.suite == s]
            f.write('<testsuite name="%s" tests="%d" failures="%d" skipped="%d">\n' % (
                escape(s), len(ts), sum(t.status in ("FAIL", "TIMEOUT") for t in ts), sum(t.status == "SKIP" for t in ts)))
            for t in ts:
                f.write('  <testcase classname="%s" name="%s" time="%.1f">' % (escape(s), escape(t.key), t.runtime))
                if t.status in ("FAIL", "TIMEOUT"):
                    f.write('<failure message="%s"/>' % escape(t.status + ": " + t.detail, {'"': "&quot;"}))
                elif t.status == "SKIP":
                    f.write('<skipped message="%s"/>' % escape(t.detail or "", {'"': "&quot;"}))
                f.write("</testcase>\n")
            f.write("</testsuite>\n")
        f.write("</testsuites>\n")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--suites", default=os.path.join(ROOT, "tools", "regress_suites.toml"))
    p.add_argument("--only", action="append", help="regex on suite name (repeatable)")
    p.add_argument("--skip", action="append", default=[], help="regex on suite name to skip")
    p.add_argument("--seeds", type=int, default=4, help="number of random stress seeds")
    p.add_argument("--seed-list", type=lambda s: [int(x, 0) for x in s.split(",")], help="explicit stress seeds")
    p.add_argument("--seed-base", type=int, default=None, help="seed of the seed generator (default: time)")
    p.add_argument("--stress-iters", type=int, default=24)
    p.add_argument("--stress-flags", type=int, default=0, help="1 = fault injection")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    p.add_argument("--timeout", type=int, help="override every per-test timeout (s)")
    p.add_argument("--out", default=os.path.join(ROOT, "build", "regress"))
    p.add_argument("--list", action="store_true")
    p.add_argument("--no-coverage", action="store_true")
    a = p.parse_args(argv)
    if a.seed_base is None:
        a.seed_base = int(time.time())

    cfg = tomllib.load(open(a.suites, "rb"))
    suites = cfg.get("suite", []) + discover(cfg)
    if a.only:
        suites = [s for s in suites if any(re.search(o, s["name"]) for o in a.only)]
    suites = [s for s in suites if not any(re.search(x, s["name"]) for x in a.skip)]

    out = os.path.abspath(a.out)
    if not a.list and os.path.isdir(out):
        shutil.rmtree(out)
    logdir = os.path.join(out, "logs")
    os.makedirs(logdir, exist_ok=True)

    tests, builds = [], []
    for s in suites:
        try:
            ts, b = expand(s, a, out)
        except RuntimeError as ex:
            t = Test(s["name"], "(discover)", [], ROOT, 0)
            t.status, t.detail = "FAIL", str(ex)[:120]
            ts, b = [t], None
        tests += ts
        if b:
            builds.append((s["name"], b))
    if a.list:
        for t in tests:
            print("%-16s %-24s seed=%-11s %s" % (t.suite, t.name, t.seed, " ".join(t.cmd)))
        return 0

    print("regression: %d tests in %d suites, %d jobs, stress seed base %d" % (
        len(tests), len(suites), a.jobs, a.seed_base), flush=True)
    # builds first, serially (parallel test runs must not race on one build)
    failed_builds = set()
    for name, b in builds:
        bt = Test(name, "(build)", b, ROOT, 3600)
        run_one(bt, logdir)
        print("  build %-16s %s %.0fs" % (name, bt.status, bt.runtime), flush=True)
        if bt.status != "PASS":
            failed_builds.add(name)
            tests.append(bt)
    todo = [t for t in tests if t.status == "NOTRUN" and t.suite not in failed_builds]
    for t in tests:
        if t.status == "NOTRUN" and t.suite in failed_builds:
            t.status, t.detail = "FAIL", "suite build failed"
    t_start = time.time()
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for t in cf.as_completed([ex.submit(run_one, t, logdir) for t in todo]):
            r = t.result()
            print("  %-7s %-16s %-24s %8s %6.1fs %s" % (r.status, r.suite, r.name, "" if r.seed is None else r.seed,
                                                       r.runtime, r.detail), flush=True)
    wall = time.time() - t_start

    # ---- summary ----
    lines = ["%-7s  %-16s  %-26s  %-11s  %8s  %s" % ("STATUS", "SUITE", "TEST", "SEED", "TIME", "DETAIL"),
             "-" * 100]
    order = {"FAIL": 0, "TIMEOUT": 1, "SKIP": 2, "PASS": 3}
    for t in sorted(tests, key=lambda t: (order.get(t.status, 9), t.suite, t.name, t.seed or 0)):
        lines.append("%-7s  %-16s  %-26s  %-11s  %7.1fs  %s" % (t.status, t.suite, t.name,
                                                              "" if t.seed is None else t.seed, t.runtime, t.detail))
    cnt = {s: sum(t.status == s for t in tests) for s in ("PASS", "FAIL", "TIMEOUT", "SKIP")}
    lines.append("-" * 100)
    lines.append("total %d: %d pass, %d fail, %d timeout, %d skip (wall %.0f s)" % (
        len(tests), cnt["PASS"], cnt["FAIL"], cnt["TIMEOUT"], cnt["SKIP"], wall))
    lines.append("REGRESSION %s" % ("PASS" if cnt["FAIL"] == cnt["TIMEOUT"] == 0 and cnt["PASS"] else "FAIL"))
    summary = "\n".join(lines)
    print("\n" + summary)
    open(os.path.join(out, "summary.txt"), "w").write(summary + "\n")
    json.dump({"seed_base": a.seed_base, "stress_iters": a.stress_iters, "stress_flags": a.stress_flags,
               "tests": [{"suite": t.suite, "name": t.name, "seed": t.seed, "status": t.status, "runtime": t.runtime,
                          "detail": t.detail, "log": t.log, "cmd": t.cmd, "cwd": t.cwd, "artifacts": t.artifacts}
                         for t in tests]}, open(os.path.join(out, "results.json"), "w"), indent=1)
    junit(tests, os.path.join(out, "junit.xml"))
    if not a.no_coverage:
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "cov_merge.py"), "--out",
                        os.path.join(out, "coverage"), out], cwd=ROOT)
    return 0 if cnt["FAIL"] == cnt["TIMEOUT"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
