#!/usr/bin/env python3
"""Negative tests of the regression's checkers and result parsers (doc/SPEC.md:
"Every checker, scoreboard, comparator and result parser has a negative test
that proves it reports failure on wrong input").

Each case feeds a checker wrong input and PASSES only if the checker reports
failure (nonzero exit, and the expected reason). A few positive controls make
sure the same checker accepts correct input. Results: <out>/results.json, IDs
"selftest/<case>" (required list dv/regress/selftest.required).

Covered here: check_results.py, check_soc_cov.py, cov_report.py (CPU coverage
holes / missing data / waivers), mutation.py (survivor, build failure, mutant
not applied, waiver without reason), run_cosim.py, run_archtest.py and
run_cachetest.py result parsing, the PMU unit testbench (PMU mutant) and the
PMU formal proof (PMU mutant). The SoC testbench checkers have their own
negative tests (scripts/soc_neg.py, make sim-neg); the Spike co-simulation
comparator and the cache scoreboards are exercised by the mutation run.
"""
import argparse
import json
import os
import shutil
import stat
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable
RESULTS = []


def sh(cmd, cwd=ROOT, timeout=3600):
    try:
        p = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def record(cid, ok, detail=""):
    RESULTS.append({"id": f"selftest/{cid}", "status": "PASS" if ok else "FAIL"})
    print(f"  {cid:34s} {'PASS' if ok else 'FAIL'}  {detail}")


def expect_fail(cid, cmd, reason, cwd=ROOT, timeout=3600):
    rc, out = sh(cmd, cwd, timeout)
    ok = rc != 0 and reason in out
    record(cid, ok, f"(exit {rc})" if ok else f"(exit {rc}, expected failure containing {reason!r})\n"
           + "\n".join("      " + l for l in out.splitlines()[-6:]))


def expect_pass(cid, cmd, cwd=ROOT, timeout=3600):
    rc, out = sh(cmd, cwd, timeout)
    record(cid, rc == 0, f"(exit {rc})" if rc == 0 else "\n".join("      " + l for l in out.splitlines()[-6:]))


def script(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("#!" + PY + "\n" + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    return path


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


# --------------------------------------------------------------------------- cases
def t_check_results(d):
    cr = f"{PY} scripts/check_results.py"
    req = w(f"{d}/cr/req.txt", "a\nb\nseed{1..2}\nna c  # not applicable in this configuration\n")
    noreason = w(f"{d}/cr/req_noreason.txt", "a\nna c\n")

    def res(name, rows):
        return w(f"{d}/cr/{name}.json", json.dumps([{"id": i, "status": s} for i, s in rows]))
    good = [("a", "PASS"), ("b", "PASS"), ("seed1", "PASS"), ("seed2", "PASS"), ("c", "N/A")]
    expect_pass("check_results/good", f"{cr} --results {res('good', good)} --required {req}")
    expect_fail("check_results/missing", f"{cr} --results {res('m', good[:3] + good[4:])} --required {req}",
                "missing / not run")
    expect_fail("check_results/unknown", f"{cr} --results {res('u', good + [('zzz', 'PASS')])} --required {req}",
                "unknown test ID")
    expect_fail("check_results/fail-not-overwritten",
                f"{cr} --results {res('f', good + [('a', 'FAIL'), ('a', 'PASS')])} --required {req}", "'a': FAIL")
    expect_fail("check_results/skipped", f"{cr} --results {res('s', [('b', 'SKIPPED') if r[0] == 'b' else r for r in good])} --required {req}",
                "'b': SKIPPED")
    expect_fail("check_results/aborted", f"{cr} --results {res('ab', [('b', 'ABORTED') if r[0] == 'b' else r for r in good])} --required {req}",
                "'b': ABORTED")
    expect_fail("check_results/na-without-reason", f"{cr} --results {res('n', [('a', 'PASS'), ('c', 'N/A')])} --required {noreason}",
                "without a reason")
    expect_fail("check_results/na-reported-pass", f"{cr} --results {res('np', good[:4] + [('c', 'PASS')])} --required {req}",
                "declared not applicable")
    expect_fail("check_results/unreadable", f"{cr} --results {d}/cr/nonexistent.json --required {req}",
                "cannot read results")


def t_check_soc_cov(d):
    cc = f"{PY} scripts/check_soc_cov.py"
    cov = w(f"{d}/sc/cov.txt", "COV arc A->B 3\nCOV arc B->C 0\nCOV pstate RUN->IDLE 2\nCOV aborted RUN->SLEEP 1\n")
    goals = w(f"{d}/sc/goals.txt", "arc * >= 1\npstate RUN->IDLE >= 1\n")
    waiv = w(f"{d}/sc/waiv.txt", "arc B->C  # unreachable in this configuration\n")
    expect_pass("check_soc_cov/good-with-waiver", f"{cc} --cov {cov} --goals {goals} --waivers {waiv}")
    expect_fail("check_soc_cov/hole", f"{cc} --cov {cov} --goals {goals}", "coverage goal not met: arc B->C")
    expect_fail("check_soc_cov/waiver-without-reason",
                f"{cc} --cov {cov} --goals {goals} --waivers {w(d + '/sc/w2.txt', 'arc B->C\n')}", "without a reason")
    expect_fail("check_soc_cov/stale-waiver",
                f"{cc} --cov {cov} --goals {goals} --waivers {w(d + '/sc/w3.txt', 'arc B->C  # r\narc A->B  # r\n')}",
                "stale waiver")
    expect_fail("check_soc_cov/missing-bin",
                f"{cc} --cov {cov} --goals {w(d + '/sc/g2.txt', 'pstate RUN->SLEEP >= 1\n')}", "missing data")
    expect_fail("check_soc_cov/aborted-is-not-coverage",
                f"{cc} --cov {cov} --goals {w(d + '/sc/g3.txt', 'pstate RUN->SLEEP >= 1\n')}", "pstate RUN->SLEEP")
    expect_fail("check_soc_cov/empty", f"{cc} --cov {w(d + '/sc/empty.txt', '')} --goals {goals}", "no COV lines")


def t_cov_report(d, build):
    cr = f"{PY} scripts/cov_report.py --verilator-coverage {shutil.which('verilator_coverage') or 'verilator_coverage'}"
    expect_fail("cov_report/no-databases", f"{cr} --build {d}/emptybuild --out {d}/cov0", "no coverage database")
    if not os.path.isdir(os.path.join(build, "cosim", "regress")):
        record("cov_report/unwaived-hole", False, "(needs the CPU regression in build/: run make cosim archtest cachetest)")
        record("cov_report/waiver-without-reason", False, "(needs build/)")
        record("cov_report/stale-waiver", False, "(needs build/)")
        return
    empty = w(f"{d}/cv/empty_waivers.txt", "")
    expect_fail("cov_report/unwaived-hole", f"{cr} --build {build} --out {d}/cov1 --waivers {empty}",
                "coverage hole cover cp_wb_error (not waived)")
    expect_fail("cov_report/waiver-without-reason",
                f"{cr} --build {build} --out {d}/cov2 --waivers {w(d + '/cv/nr.txt', 'cover cp_wb_error\n')}",
                "waiver without a reason")
    stale = open(os.path.join(ROOT, "dv/coverage_waivers.txt")).read() + "isa insn:add  # bogus\n"
    expect_fail("cov_report/stale-waiver", f"{cr} --build {build} --out {d}/cov3 --waivers {w(d + '/cv/st.txt', stale)}",
                "stale waiver isa insn:add")


def t_mutation(d, verilator):
    muts = w(f"{d}/mut/mutants.json", json.dumps([
        ["neg_noop", "rtl/core/core_alu.sv", "// Integer ALU.", "// Integer ALU (equivalent mutant).",
         "comment-only change: must survive", False],
        ["neg_syntax", "rtl/core/core_alu.sv", "// Integer ALU.", "this is not SystemVerilog;",
         "syntax error: must fail to build", False],
        ["neg_missing", "rtl/core/core_alu.sv", "text that is not in the file", "x",
         "edit does not apply", False]]))
    out = f"{d}/mut/out"
    rc, log = sh(f"{PY} scripts/mutation.py --mutants {muts} --seeds 2 --jobs 3 --verilator {verilator} "
                 f"--out {out} --waivers {d}/mut/none.txt")
    try:
        st = {r["id"]: r["status"] for r in json.load(open(f"{out}/summary.json"))["results"]}
    except (OSError, ValueError, KeyError):
        st = {}
    record("mutation/survivor-fails-run", rc != 0 and st.get("neg_noop") == "SURVIVED", f"(exit {rc}, {st})")
    record("mutation/build-failure-fails-run", rc != 0 and st.get("neg_syntax") == "BUILD-FAIL", f"({st.get('neg_syntax')})")
    record("mutation/not-applied-fails-run", rc != 0 and st.get("neg_missing") == "NOT-APPLIED", f"({st.get('neg_missing')})")
    m2 = w(f"{d}/mut/m2.json", json.dumps([["neg_missing", "rtl/core/core_alu.sv", "not in the file", "x", "x", False]]))
    expect_fail("mutation/waiver-without-reason",
                f"{PY} scripts/mutation.py --mutants {m2} --out {d}/mut/out2 --waivers {w(d + '/mut/w.txt', 'neg_missing\n')}",
                "waiver without a reason")


def t_runners(d):
    # run_cosim: a simulator that exits 0 without "[tb] PASS", and one that says PASS but exits 1
    nopass = script(f"{d}/rc/bin/nopass", "print('[tb] cycles=1 retired=1 traps=0 irqs=0')\n")
    badexit = script(f"{d}/rc/bin/badexit", "import sys\nprint('[tb] PASS')\nsys.exit(1)\n")
    for cid, b in (("run_cosim/exit0-without-pass", nopass), ("run_cosim/pass-with-nonzero-exit", badexit)):
        expect_fail(cid, f"{PY} scripts/run_cosim.py --bin {b} --seeds 1 --directed 0 --jobs 1 --out {d}/rc/out_{os.path.basename(b)}",
                    "COSIM: 0/1 seeds passed")
    # run_archtest: DUT signature differs from the Spike reference
    wrongsig = script(f"{d}/ra/wrongsig", "import sys\n"
                      "sig=[a[5:] for a in sys.argv if a.startswith('+sig=')][0]\n"
                      "open(sig,'w').write('deadbeef\\n'*8)\nprint('[tb] PASS')\n")
    spike = os.path.join(os.environ.get("SPIKE_PREFIX", "/opt/spike"), "bin", "spike")
    expect_fail("run_archtest/signature-mismatch",
                f"{PY} scripts/run_archtest.py --bin {wrongsig} --suite third_party/riscv-arch-test --spike {spike} "
                f"--out {d}/ra/out --jobs 1 --only I/add-01", "signature mismatch")
    # run_cachetest: bench prints PASS and exits 0 but logged an %Error
    b = f"{d}/ct"
    for sub, name in (("dc", "Vtb_dcache"), ("ic", "Vtb_icache"), ("mux", "Vtb_axil_mux")):
        os.makedirs(f"{b}/{sub}", exist_ok=True)
        bench = {"dc": "dcache", "ic": "icache", "mux": "axilmux"}[sub]
        script(f"{b}/{sub}/{name}", f"print('%Error: scoreboard mismatch')\nprint('[tb_{bench}] PASS')\n")
    expect_fail("run_cachetest/error-with-pass", f"{PY} scripts/run_cachetest.py --build {b} --seeds 1 --n 10",
                "seed 1: FAIL")


def t_fw(d):
    """Firmware flow: tools/fw_results.py + check_results.py (the stage-1
    checker) and tools/mkimage.py must reject wrong input."""
    fwd = f"{d}/fw"
    req = w(f"{fwd}/req.txt", "fw/1\nfw/2\nna fw/3  # not on this platform\nfw/suite-result\nfw/exit\n")
    tail = "SUITE DONE pass=2 fail=0 skip=1 signature=0x600d0002\nSUITE RESULT: PASS\nPASS\n"

    def chk(cid, log, expect_ok, reason=""):
        lp = w(f"{fwd}/{cid}.log", log)
        rp = f"{fwd}/{cid}.json"
        cmd = (f"{PY} tools/fw_results.py --log {lp} --out {rp} && "
               f"{PY} scripts/check_results.py --name {cid} --results {rp} --required {req}")
        if expect_ok:
            expect_pass(f"fw_results/{cid}", cmd)
        else:
            expect_fail(f"fw_results/{cid}", cmd, reason)

    good = "[TEST   1] a PASS\n[TEST   2] b PASS\n[TEST   3] c SKIP (needs x)\n"
    chk("good", good + tail, True)
    chk("good-soc-prefix", "".join("[uart] " + l + "\n" for l in (good + tail).splitlines()), True)
    # the firmware branch's parser accepted both of these (stage 2 report)
    chk("unknown-id-with-missing", "[TEST   1] a PASS\n[TEST 999] x PASS\n[TEST   3] c SKIP\n" + tail, False,
        "required test 'fw/2' missing")
    chk("unknown-id", good + "[TEST  42] x PASS\n" + tail, False, "unknown test ID 'fw/42'")
    chk("pass-after-fail", "[TEST   1] a FAIL (code 7)\n[TEST   1] a PASS\n[TEST   2] b PASS\n"
        "[TEST   3] c SKIP\n" + tail, False, "'fw/1': FAIL")
    chk("skip-of-required", "[TEST   1] a PASS\n[TEST   2] b SKIP (needs y)\n[TEST   3] c SKIP\n" + tail, False,
        "'fw/2': N/A")
    chk("na-test-ran", "[TEST   1] a PASS\n[TEST   2] b PASS\n[TEST   3] c PASS\n" + tail, False,
        "declared not applicable but reported")
    chk("no-exit-line", good + "SUITE RESULT: PASS\n", False, "required test 'fw/exit' missing")
    chk("exit-fail", good + "SUITE RESULT: PASS\nFAIL 0xbad00001\n", False, "'fw/exit': FAIL")
    chk("suite-fail", good + "SUITE RESULT: FAIL\nPASS\n", False, "'fw/suite-result': FAIL")
    chk("truncated", "[TEST   1] a PASS\n", False, "missing")

    # image builder: every header rule of doc/BOOT_ABI.md
    import struct

    def img(cid, entry=0x10001020, ver=1, load=0x10001000, rsvd=0, extra=0, expect_ok=False, reason=""):
        body = b"\x13\x00\x00\x00" * 8
        size = 32 + len(body) + extra
        hdr = struct.pack("<8I", 0x5041504C, ver, load, size, entry, 0, rsvd, 0)
        raw = f"{fwd}/{cid}.raw"
        open(raw, "wb").write(hdr + body + b"\0" * extra)
        cmd = (f"{PY} tools/mkimage.py app {raw} {fwd}/{cid}.img {fwd}/{cid}.hex "
               f"--mem-base 0x10000000 --load-addr 0x10001000")
        if expect_ok:
            expect_pass(f"mkimage/{cid}", cmd)
        else:
            expect_fail(f"mkimage/{cid}", cmd, reason)

    img("good", expect_ok=True)
    img("unaligned-entry", entry=0x10001022, reason="not 4-byte aligned")
    img("entry-in-header", entry=0x10001004, reason="outside the image body")
    img("entry-past-end", entry=0x10001040, reason="outside the image body")
    img("bad-version", ver=2, reason="header version")
    img("bad-load-address", load=0x10002000, reason="load address")
    img("reserved-nonzero", rsvd=1, reason="reserved header words")
    img("size-not-word-multiple", extra=2, reason="multiple of 4")

    # monitor session checker
    spec = w(f"{fwd}/mon.txt", "< banner\n> peek x\n< ^0x1: 0x2$\n! ERR\n")
    good_log = w(f"{fwd}/mon_good.log", "banner\nmon> peek x\n0x1: 0x2\nmon> ")
    bad_log = w(f"{fwd}/mon_bad.log", "banner\nmon> peek x\nERR fault 0x1\nmon> ")
    short_log = w(f"{fwd}/mon_short.log", "banner\n")
    expect_pass("monitor_check/good", f"{PY} tools/monitor_check.py check {spec} {good_log}")
    expect_fail("monitor_check/missing-and-denied", f"{PY} tools/monitor_check.py check {spec} {bad_log}",
                "unexpected /ERR/")
    expect_fail("monitor_check/session-ended-early", f"{PY} tools/monitor_check.py check {spec} {short_log}",
                "no output")


PMU_MUTANTS = [
    # voltage not raised before a speed-up: SVA a_vsel_sufficient / a_dvfs_vup,
    # reference model
    ("vsel-mutant", "          vsel_q   <= vup_level;\n", "          vsel_q   <= vsel_q;\n"),
    # wake mask ignored (stage-1 open item 3): SVA a_wake_masked, the bench's
    # masked-noise check
    ("wake-mask-mutant", "  assign wake     = |(wake_src & wake_mask_q);\n", "  assign wake     = |wake_src;\n"),
    # watchdog reset isolates a running core with a bus transaction in flight
    # (audit B17): SVA a_iso_on_bus_idle, the bench's retry check
    ("wdt-bus-mutant", "          if (bus_idle_i) state_d = ST_ISO_ON;\n          else            state_d = ST_CLK_UNGATE;",
     "          state_d = ST_ISO_ON;"),
    # watchdog reset reported as a resume: SVA a_wdt_status, the bench's
    # STATUS check
    ("wdt-resume-mutant", "        st_resume_q      <= !wdt_seq_q;\n", "        st_resume_q      <= 1'b1;\n"),
]


def t_pmu(d, verilator):
    # PMU mutants: the unit bench and the formal proof must both fail.
    src = open(os.path.join(ROOT, "rtl/aon/pmu.sv")).read()
    for name, old, new in PMU_MUTANTS:
        if old not in src:
            record(f"tb_pmu/{name}", False, "(mutant text not found in rtl/aon/pmu.sv)")
            record(f"formal_pmu/{name}", False, "(mutant text not found)")
            continue
        t = f"{d}/pmu-{name}"
        w(f"{t}/rtl/aon/pmu.sv", src.replace(old, new, 1))
        shutil.copytree(os.path.join(ROOT, "rtl/include"), f"{t}/rtl/include", dirs_exist_ok=True)
        rc, out = sh(f"{verilator} --binary --timing --timescale 1ns/1ps -j 0 -DSVA_ON --assert -Wno-fatal -Wno-WIDTH "
                     f"-Wno-lint -Wno-style -Wno-MULTIDRIVEN --top-module tb_pmu -Mdir {t}/obj -o Vtb_pmu "
                     f"-I{t}/rtl/include {t}/rtl/aon/pmu.sv {ROOT}/sim/pmu/tb_pmu.sv")
        if rc:
            record(f"tb_pmu/{name}", False, "(mutant bench did not build)\n" + out[-400:])
        else:
            # caught by a PMU SVA or a bench check / the reference model
            expect_fail(f"tb_pmu/{name}", f"{t}/obj/Vtb_pmu +episodes=200", "Assertion failed in", cwd=t)
        shutil.copytree(os.path.join(ROOT, "formal"), f"{t}/formal", dirs_exist_ok=True)
        expect_fail(f"formal_pmu/{name}", f"sby -f -d {t}/sby_prove pmu.sby prove", "Assert failed",
                    cwd=f"{t}/formal")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(ROOT, "build/selftest"))
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"))
    a = ap.parse_args()
    d = os.path.abspath(a.out)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    groups = [("check_results", lambda: t_check_results(d)), ("check_soc_cov", lambda: t_check_soc_cov(d)),
              ("cov_report", lambda: t_cov_report(d, os.path.abspath(a.build))), ("runners", lambda: t_runners(d)),
              ("fw", lambda: t_fw(d)),
              ("pmu", lambda: t_pmu(d, a.verilator)), ("mutation", lambda: t_mutation(d, a.verilator))]
    for name, fn in groups:
        try:
            fn()
        except Exception as e:   # a crashing self-test is a failure, never a skip
            record(f"{name}/crash", False, repr(e))
    json.dump(RESULTS, open(os.path.join(d, "results.json"), "w"), indent=1)
    bad = [r["id"] for r in RESULTS if r["status"] != "PASS"]
    print(f"SELFTEST: {len(RESULTS) - len(bad)}/{len(RESULTS)} negative tests detected the injected failure"
          + (f"; failing: {bad}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
