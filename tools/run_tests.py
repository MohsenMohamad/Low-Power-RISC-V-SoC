#!/usr/bin/env python3
"""Build and run every firmware check; print a pass/fail summary.

Steps (each is PASS, FAIL or SKIPPED-with-reason; nothing is assumed):
  build    firmware for lpsoc/picorv32, spike/rv32m, lpsoc/rv32m
  lint     Verilator -Wall lint of the PicoRV32 bring-up SoC
  sim      Verilator build of the SoC testbench
  pico     full validation suite on the PicoRV32 SoC (RTL simulation)
  spike    full validation suite on Spike (--priv=M and --priv=MSU)
  monitor  scripted UART monitor sessions (application, boot ROM fallback)
  selftest a deliberately failing test must be reported as FAIL on both
           platforms (checks the pass/fail reporting path itself)

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
SIMBIN = os.path.join(ROOT, "build", "picorv32", "obj", "Vtb_top")
FW = os.path.join(ROOT, "build", "fw")

# Tests that must be skipped (missing capability) on each platform; anything
# else skipped is an error, so a broken capability probe cannot hide tests.
PICO_SKIPS = {14}                                   # no access-fault exceptions
SPIKE_SKIPS = {23, 24, 30, 31, 32, 33, 34, 35, 41, 42, 43, 44, 45, 46,
               50, 51, 52, 60, 61, 70, 72, 73}           # no SoC peripherals
PICO_MIN_PASS = 37
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
    have_vl = shutil.which("verilator") is not None
    spike = find_spike()

    # ---------------- build ----------------
    if not have_gcc:
        record("build firmware", None, "riscv64-unknown-elf-gcc not found")
        fw_ok = False
    else:
        rc, _, t = run(["make", "-C", "fw", "all-configs"], "build_fw.log", 600)
        fw_ok = rc == 0
        record("build firmware (3 configs)", fw_ok, "see build_fw.log" if rc else "lpsoc/picorv32 spike/rv32m lpsoc/rv32m", t)
        if fw_ok:
            rc, _, t = run(["make", "-C", "fw", "PLATFORM=spike", "ARCH=rv32m",
                            "BUILD=%s/selftest-spike" % FW, "EXTRA_CFLAGS=-DSUITE_SELFTEST"], "build_selftest.log", 600)
            rc2, _, t2 = run(["make", "-C", "fw", "PLATFORM=lpsoc", "ARCH=picorv32",
                              "BUILD=%s/selftest-lpsoc" % FW, "EXTRA_CFLAGS=-DSUITE_SELFTEST"], "build_selftest_lpsoc.log", 600)
            fw_ok_self = rc == 0 and rc2 == 0
            record("build selftest firmware", fw_ok_self, "", t + t2)

    # ---------------- RTL ----------------
    sim_ok = False
    if not have_vl:
        record("lint (verilator -Wall)", None, "verilator not found")
        record("build simulation", None, "verilator not found")
    else:
        rc, text, t = run(["make", "-C", "platform/picorv32", "lint"], "lint.log", 600)
        nwarn = len(re.findall(r"^%Warning", text, re.M))
        record("lint (verilator -Wall)", rc == 0 and nwarn == 0, "%d warnings" % nwarn, t)
        rc, _, t = run(["make", "-C", "platform/picorv32", "sim"], "build_sim.log", 1200)
        sim_ok = rc == 0 and os.path.exists(SIMBIN)
        record("build simulation", sim_ok, "", t)

    pico = os.path.join(FW, "lpsoc-picorv32")
    # ---------------- PicoRV32 SoC suite ----------------
    if sim_ok and fw_ok:
        rc, text, t = run([SIMBIN, "+rom_hex=%s/rom.hex" % pico, "+ram_hex=%s/app.hex" % pico,
                           "+timeout=400000000"], "pico_suite.log", 3600)
        ok, detail = suite_verdict(text, PICO_SKIPS, PICO_MIN_PASS)
        ok = ok and "[TB] SIM RESULT: PASS" in text and rc == 0
        record("suite on PicoRV32 SoC (RTL)", ok, detail, t)
    else:
        record("suite on PicoRV32 SoC (RTL)", None, "simulation or firmware build missing")

    # ---------------- Spike suite ----------------
    if spike and fw_ok:
        for priv in ("M", "MSU"):
            rc, text, t = run([spike, "--priv=" + priv, "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                               os.path.join(FW, "spike-rv32m", "app.elf")], "spike_suite_%s.log" % priv, 600)
            ok, detail = suite_verdict(text, SPIKE_SKIPS, SPIKE_MIN_PASS)
            record("suite on Spike --priv=%s" % priv, ok and rc == 0, detail + ", exit %d" % rc, t)
    else:
        record("suite on Spike", None, "spike not found" if not spike else "firmware build failed")

    # ---------------- monitor sessions ----------------
    if sim_ok and fw_ok:
        for name, args in (("app", ["+ram_hex=%s/app.hex" % pico]), ("rom", [])):
            spec = os.path.join(ROOT, "platform", "picorv32", "tests", "monitor_%s.txt" % name)
            uin = os.path.join(OUT, "monitor_%s_in.txt" % name)
            ulog = os.path.join(OUT, "monitor_%s_uart.log" % name)
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "monitor_check.py"), "gen", spec, uin], check=True)
            rc, text, t = run([SIMBIN, "+rom_hex=%s/rom.hex" % pico, "+monitor", "+uart_in=" + uin,
                               "+uart_log=" + ulog, "+timeout=200000000"] + args, "monitor_%s_sim.log" % name, 1800)
            crc, ctext, _ = run([sys.executable, os.path.join(ROOT, "tools", "monitor_check.py"), "check", spec, ulog],
                                "monitor_%s_check.log" % name, 60)
            ok = rc == 0 and "[TB] SIM RESULT: PASS" in text and crc == 0
            record("monitor session (%s)" % name, ok, ctext.strip().splitlines()[-1] if ctext.strip() else "", t)
    else:
        record("monitor sessions", None, "simulation or firmware build missing")

    # ---------------- reporting self-test ----------------
    if spike and fw_ok:
        rc, text, t = run([spike, "--priv=M", "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                           os.path.join(FW, "selftest-spike", "app.elf")], "selftest_spike.log", 600)
        ok = (rc != 0 and re.search(r"^\[TEST  99\] selftest_must_fail +FAIL", text, re.M)
              and re.search(r"^\[TEST  98\] selftest_must_skip +SKIP", text, re.M)
              and "signature=0xbad00001" in text and "SUITE RESULT: FAIL" in text)
        record("selftest: FAIL reported (Spike)", bool(ok), "exit %d" % rc, t)
    if sim_ok and fw_ok:
        st = os.path.join(FW, "selftest-lpsoc")
        rc, text, t = run([SIMBIN, "+rom_hex=%s/rom.hex" % st, "+ram_hex=%s/app.hex" % st, "+test=99",
                           "+timeout=20000000"], "selftest_pico.log", 600)
        ok = ("[TB] SIM RESULT: FAIL code=0xbad00001" in text
              and re.search(r"^\[TEST  99\] selftest_must_fail +FAIL", text, re.M))
        record("selftest: FAIL reported (SoC)", bool(ok), "", t)

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
