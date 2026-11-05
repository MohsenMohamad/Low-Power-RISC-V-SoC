#!/usr/bin/env python3
"""Build and run every firmware check; print a pass/fail summary.

Steps (each is PASS, FAIL or SKIPPED-with-reason; nothing is assumed):
  build    firmware for spike/rv32m, lpsoc/rv32m
  spike    full validation suite on Spike (--priv=M and --priv=MSU)
  selftest a deliberately failing test must be reported as FAIL

Logs: build/test/*.log, summary: build/test/summary.txt
"""
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "test")
FW = os.path.join(ROOT, "build", "fw")

# Tests that must be skipped (missing capability) on each platform; anything
# else skipped is an error, so a broken capability probe cannot hide tests.
SPIKE_SKIPS = {23, 24, 30, 31, 32, 33, 34, 35, 41, 42, 43, 44, 45, 46,
               50, 51, 52, 60, 61, 70, 72, 73}           # no SoC peripherals
SPIKE_MIN_PASS = 17

results = []


def find_spike():
    for c in (os.environ.get("SPIKE"), shutil.which("spike"), "/opt/spike/bin/spike"):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def run(cmd, log, timeout):
    t0 = time.time()
    with open(os.path.join(OUT, log), "w") as f:
        try:
            p = subprocess.run(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            f.write("\n*** TIMEOUT after %d s\n" % timeout)
            rc = -1
    text = open(os.path.join(OUT, log), errors="replace").read()
    return rc, text, time.time() - t0


def record(name, ok, detail, secs=0.0):
    status = {True: "PASS", False: "FAIL", None: "SKIPPED"}[ok]
    results.append((name, status, detail, secs))
    print("%-28s %-8s %6.1fs  %s" % (name, status, secs, detail), flush=True)


SIM_ERROR_RE = re.compile(r"%Error|%Warning|\[TB\] UART framing|\[TB\] CPU entered TRAP|PMU: |retention mode")


def sim_errors(text):
    """Simulation-time checks ($error from PMU/SRAM models, testbench)."""
    m = SIM_ERROR_RE.search(text)
    return None if not m else text[m.start():].splitlines()[0]


def suite_verdict(text, must_skip, min_pass):
    """Parse '[TEST n] name RESULT' lines and check them against expectations."""
    res = {}
    for m in re.finditer(r"^\[TEST +(\d+)\] +(\S+) +(PASS|FAIL|SKIP)", text, re.M):
        res[int(m.group(1))] = m.group(3)
    passed = sorted(i for i, r in res.items() if r == "PASS")
    failed = sorted(i for i, r in res.items() if r == "FAIL")
    skipped = {i for i, r in res.items() if r == "SKIP"}
    problems = []
    if failed:
        problems.append("failed %s" % failed)
    if skipped != must_skip:
        problems.append("skip set %s, expected %s" % (sorted(skipped), sorted(must_skip)))
    if len(passed) < min_pass:
        problems.append("only %d passed (< %d)" % (len(passed), min_pass))
    if "SUITE RESULT: PASS" not in text:
        problems.append("no 'SUITE RESULT: PASS'")
    detail = "%d pass, %d fail, %d skip" % (len(passed), len(failed), len(skipped))
    return (not problems), detail + ("; " + "; ".join(problems) if problems else "")


def main():
    os.makedirs(OUT, exist_ok=True)
    have_gcc = shutil.which("riscv64-unknown-elf-gcc") is not None
    spike = find_spike()

    # ---------------- build ----------------
    if not have_gcc:
        record("build firmware", None, "riscv64-unknown-elf-gcc not found")
        fw_ok = False
    else:
        rc, _, t = run(["make", "-C", "fw", "all-configs"], "build_fw.log", 600)
        fw_ok = rc == 0
        record("build firmware", fw_ok, "see build_fw.log" if rc else "spike/rv32m lpsoc/rv32m", t)
        if fw_ok:
            rc, _, t = run(["make", "-C", "fw", "PLATFORM=spike", "ARCH=rv32m",
                            "BUILD=%s/selftest-spike" % FW, "EXTRA_CFLAGS=-DSUITE_SELFTEST"], "build_selftest.log", 600)
            record("build selftest firmware", rc == 0, "", t)

    # ---------------- Spike suite ----------------
    if spike and fw_ok:
        for priv in ("M", "MSU"):
            rc, text, t = run([spike, "--priv=" + priv, "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                               os.path.join(FW, "spike-rv32m", "app.elf")], "spike_suite_%s.log" % priv, 600)
            ok, detail = suite_verdict(text, SPIKE_SKIPS, SPIKE_MIN_PASS)
            record("suite on Spike --priv=%s" % priv, ok and rc == 0, detail + ", exit %d" % rc, t)
    else:
        record("suite on Spike", None, "spike not found" if not spike else "firmware build failed")

    # ---------------- reporting self-test ----------------
    if spike and fw_ok:
        rc, text, t = run([spike, "--priv=M", "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                           os.path.join(FW, "selftest-spike", "app.elf")], "selftest_spike.log", 600)
        ok = (rc != 0 and re.search(r"^\[TEST  99\] selftest_must_fail +FAIL", text, re.M)
              and re.search(r"^\[TEST  98\] selftest_must_skip +SKIP", text, re.M)
              and "signature=0xbad00001" in text and "SUITE RESULT: FAIL" in text)
        record("selftest: FAIL reported (Spike)", bool(ok), "exit %d" % rc, t)
    # ---------------- summary ----------------
    nfail = sum(1 for r in results if r[1] == "FAIL")
    nskip = sum(1 for r in results if r[1] == "SKIPPED")
    with open(os.path.join(OUT, "summary.txt"), "w") as f:
        for r in results:
            f.write("%-28s %-8s %6.1fs  %s\n" % (r[0], r[1], r[3], r[2]))
    print("-" * 72)
    print("make test: %d steps, %d failed, %d skipped -> %s" %
          (len(results), nfail, nskip, "FAIL" if nfail else ("PASS (with skipped steps)" if nskip else "PASS")))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
