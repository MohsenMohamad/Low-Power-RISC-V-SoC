#!/usr/bin/env python3
"""Firmware runs of `make test` (stage 2). Each mode writes <out>/results.json
for the stage-1 checker (scripts/check_results.py), which the Makefile runs
against a required-test list; this script never decides PASS by itself beyond
recording what each run produced.

  suite    validation suite on the integrated SoC (sim/tb_soc.sv, Verilator,
           boot ROM + suite image, host boot argument "run all"). Results:
           one per [TEST n] line (tools/fw_results.py), the suite result, the
           exit line, and fw/bench (the bench verdict: TEST PASSED, exit 0).
           Also writes the power-state coverage file for check_soc_cov.py.
  spike    validation suite on Spike, --priv=M and --priv=MSU (results_M.json,
           results_MSU.json: each checked by the Makefile; fw/process-exit is
           the HTIF exit status)
  monitor  scripted UART monitor sessions on the SoC: the application monitor
           and the boot ROM fallback monitor (no image). monitor/<name> passes
           only if tools/monitor_check.py accepts the UART log and the bench
           passed.
  neg      firmware-flow negative tests: each run must FAIL for the reason it
           provokes (a run that passes, or fails for another reason, is FAIL):
             soc-must-fail      selftest build, test 99 (failing CHECK) on the SoC
             soc-idle-abort     selftest build, test 97 (IDLE with a wake event
                                already pending reported as a completed IDLE)
             spike-selftest     selftest build on Spike: 99 FAIL, 98 SKIP,
                                nonzero exit
             rom-unaligned-entry an image whose entry point is not 4-byte
                                aligned (header CRC correct): the boot ROM
                                must reject it and start its monitor
             rom-bad-image-crc  an image with a wrong CRC: rejected likewise
  dbg      debug application (fw/debug, doc/DEBUG_SPEC.md) on the integrated
           SoC, boot argument = test id, host arguments = seed / iterations /
           flags. Crash dumps are judged by tools/dbg_decode.py (CRC, reason,
           mcause), the fault-injection runs by tools/triage.py:
             dbg/drv              debug drivers and wiring (W21 B15 B16 W23)
             dbg/stress-s<seed>   seeded random stress test
             dbg/stress-repro     same seed twice: identical operation log
             dbg/crash-illegal    expected crash: dump with mcause 2
             dbg/crash-misalign   expected crash: dump with mcause 4, mtval
             dbg/hang             watchdog reset of PD_CPU, post-mortem dump
             dbg/divtest          trace vs Spike: no divergence
             dbg/inject-s<seed>   stress with fault injection: must crash
                                  with a valid dump
             dbg/triage           triage groups every injected failure by its
                                  dump signature; a replay reproduces it
             dbg-neg/stress-abort negative test: every sleep of the stress test
                                  is aborted (wake already pending): must FAIL
             dbg-neg/drv-abort    negative test: the driver test's SLEEP and IDLE
                                  are aborted: must FAIL
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable


def run(cmd, log, timeout):
    try:
        p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        out += f"\n*** wall-clock timeout after {timeout} s\n"
        rc = 124
    with open(log, "w") as f:
        f.write(" ".join(cmd) + "\n" + out)
    return rc, out


def fw_results(log, prefix):
    import importlib.util
    spec = importlib.util.spec_from_file_location("fw_results", os.path.join(ROOT, "tools/fw_results.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.convert(open(log, errors="replace").read(), prefix)


def bench_ok(rc, out):
    return rc == 0 and "[tb] TEST PASSED" in out


def save(out_dir, results):
    json.dump(results, open(os.path.join(out_dir, "results.json"), "w"), indent=1)
    bad = [r["id"] for r in results if r["status"] not in ("PASS", "N/A")]
    print(f"FW-RUN: {len(results)} results, {len(bad)} not passing" + (f": {bad[:10]}" if bad else ""))


def sim_cmd(a, rom, ram=None, extra=()):
    cmd = [a.vl, f"+rom={rom}"]
    if ram:
        cmd.append(f"+ram={ram}")
    return cmd + list(extra)


# ---------------------------------------------------------------------------
def m_suite(a):
    log = os.path.join(a.out, "suite_soc.log")
    rc, out = run(sim_cmd(a, f"{a.fw}/rom.hex", f"{a.fw}/suite.hex",
                          ["+bootarg=8000ffff", "+timeout=2000000000", f"+cov={a.out}/cov_suite.txt"]),
                  log, a.timeout)
    res = fw_results(log, "fw")
    res.append({"id": "fw/bench", "status": "PASS" if bench_ok(rc, out) else "FAIL"})
    for l in out.splitlines():
        if re.match(r"^\[uart\] (SUITE DONE|\[TEST|    OP\d|    \d+ (ticks|random|iterations))", l) or "[tb] TEST" in l:
            print("  " + l)
    save(a.out, res)


def m_spike(a):
    res = []
    for priv in ("M", "MSU"):
        log = os.path.join(a.out, f"spike_{priv}.log")
        rc, out = run([a.spike, f"--priv={priv}", "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                       a.elf], log, a.timeout)
        r = fw_results(log, "fw")
        r.append({"id": "fw/process-exit", "status": "PASS" if rc == 0 else "FAIL"})
        print(f"  spike --priv={priv}: exit {rc}, " +
              (re.search(r"SUITE DONE.*", out).group(0) if re.search(r"SUITE DONE.*", out) else "no SUITE DONE"))
        json.dump(r, open(os.path.join(a.out, f"results_{priv}.json"), "w"), indent=1)
        res += [dict(x, id=f"spike-{priv}/" + x["id"]) for x in r]
    save(a.out, res)


def m_monitor(a):
    res = []
    for name, ram, timeout_ns in (("app", f"{a.fw}/suite.hex", 2000000000), ("rom", None, 500000000)):
        spec = os.path.join(ROOT, "fw/tests/monitor", f"monitor_{name}.txt")
        uin = os.path.join(a.out, f"monitor_{name}_in.txt")
        ulog = os.path.join(a.out, f"monitor_{name}_uart.log")
        subprocess.run([PY, os.path.join(ROOT, "tools/monitor_check.py"), "gen", spec, uin], check=True)
        rc, out = run(sim_cmd(a, f"{a.fw}/rom.hex", ram,
                              [f"+uart_in={uin}", f"+uart_log={ulog}", f"+timeout={timeout_ns}",
                               f"+cov={a.out}/cov_monitor_{name}.txt"]),
                      os.path.join(a.out, f"monitor_{name}_sim.log"), a.timeout)
        crc, cout = run([PY, os.path.join(ROOT, "tools/monitor_check.py"), "check", spec, ulog],
                        os.path.join(a.out, f"monitor_{name}_check.log"), 60)
        ok = bench_ok(rc, out) and crc == 0
        print(f"  monitor {name}: bench {'PASS' if bench_ok(rc, out) else 'FAIL'}; "
              + (cout.strip().splitlines()[-1] if cout.strip() else "no checker output"))
        if crc:
            print("    " + "\n    ".join(cout.strip().splitlines()[:10]))
        res.append({"id": f"monitor/{name}", "status": "PASS" if ok else "FAIL"})
    save(a.out, res)


def write_bad_image(src_img, dst_hex, how):
    """Copy an application image, break one header rule, keep the CRC
    consistent unless the CRC is what is broken, write a RAM hex file."""
    data = bytearray(open(src_img, "rb").read())
    if how == "unaligned-entry":
        entry = struct.unpack_from("<I", data, 16)[0]
        struct.pack_into("<I", data, 16, entry + 2)
        struct.pack_into("<I", data, 20, zlib.crc32(bytes(data[32:])) & 0xFFFFFFFF)
    elif how == "bad-crc":
        struct.pack_into("<I", data, 20, (zlib.crc32(bytes(data[32:])) ^ 1) & 0xFFFFFFFF)
    with open(dst_hex, "w") as f:
        f.write("@%x\n" % (0x1000 // 4))
        for i in range(0, len(data), 4):
            f.write("%08x\n" % struct.unpack_from("<I", data, i)[0])


def m_neg(a):
    res = []

    def case(cid, ok, detail):
        print(f"  fw-neg/{cid:22s} {'OK: failure detected' if ok else 'NOT DETECTED'} {detail}")
        res.append({"id": f"fw-neg/{cid}", "status": "PASS" if ok else "FAIL"})

    st_soc = os.path.join(ROOT, "build/fw/lpsoc-selftest")
    st_spk = os.path.join(ROOT, "build/fw/spike-selftest")
    for plat, b in (("lpsoc", st_soc), ("spike", st_spk)):
        rc, out = run(["make", "-C", "fw", f"PLATFORM={plat}", f"BUILD={b}", "EXTRA_CFLAGS=-DSUITE_SELFTEST"],
                      os.path.join(a.out, f"build_selftest_{plat}.log"), 1200)
        if rc:
            print(out[-2000:])
            case(f"build-selftest-{plat}", False, "(selftest firmware did not build)")
            save(a.out, res)
            return

    def soc_test(cid, test_id, want_line):
        log = os.path.join(a.out, f"{cid}.log")
        rc, out = run(sim_cmd(a, f"{st_soc}/rom.hex", f"{st_soc}/suite.hex",
                              [f"+bootarg={0x80000000 | test_id:08x}", f"+cov={a.out}/cov_{cid}.txt"]),
                      log, a.timeout)
        r = {x["id"]: x["status"] for x in fw_results(log, "fw")}
        ok = (rc != 0 and "[tb] TEST FAILED" in out and r.get(f"fw/{test_id}") == "FAIL"
              and r.get("fw/exit") == "FAIL" and re.search(want_line, out) is not None)
        case(cid, ok, f"(exit {rc}, test {test_id}: {r.get(f'fw/{test_id}')})")

    soc_test("soc-must-fail", 99, r"CHECK FAILED: 1 \+ 1 == 3")
    soc_test("soc-idle-abort", 97, r"CHECK FAILED: r == PM_WOKE")

    log = os.path.join(a.out, "spike-selftest.log")
    rc, out = run([a.spike, "--priv=M", "--isa=rv32im_zicsr_zifencei", "-m0x80000000:0x100000",
                   f"{st_spk}/suite.elf"], log, a.timeout)
    r = {x["id"]: x["status"] for x in fw_results(log, "fw")}
    ok = (rc != 0 and r.get("fw/99") == "FAIL" and r.get("fw/98") == "N/A" and r.get("fw/97") == "N/A"
          and r.get("fw/exit") == "FAIL" and "signature=0xbad00001" in out)
    case("spike-selftest", ok, f"(exit {rc})")

    for cid, how in (("rom-unaligned-entry", "unaligned-entry"), ("rom-bad-image-crc", "bad-crc")):
        hexf = os.path.join(a.out, f"{cid}.hex")
        write_bad_image(f"{a.fw}/suite.img", hexf, how)
        rc, out = run(sim_cmd(a, f"{a.fw}/rom.hex", hexf, ["+timeout=60000000", f"+cov={a.out}/cov_{cid}.txt"]),
                      os.path.join(a.out, f"{cid}.log"), a.timeout)
        ok = (rc != 0 and "[uart] [ROM] no valid image" in out and "[APP]" not in out
              and "[tb] FAIL: timeout" in out)
        case(cid, ok, f"(exit {rc}: ROM {'rejected' if 'no valid image' in out else 'did not reject'} the image)")
    save(a.out, res)


# ---------------------------------------------------------------------------
def _tool(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, "tools", name + ".py"))
    m = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    spec.loader.exec_module(m)
    return m


def dbg_dumps(uart_log):
    """Crash dumps of a UART log (tools/dbg_decode.py), [] if none / unreadable."""
    dec = _tool("dbg_decode")
    try:
        return dec.parse_dumps(open(uart_log, errors="replace").read())
    except (OSError, dec.DumpError):
        return []


def m_dbg(a):
    import concurrent.futures as cf
    seeds = [int(x, 0) for x in a.dbg_seeds.split()]
    inject = [int(x, 0) for x in a.dbg_inject_seeds.split()]
    img = f"{a.fw}/dbgapp.hex"

    def sim(name, test, seed=0, iters=0, flags=0, timeout_ns=400000000):
        ulog = os.path.join(a.out, f"{name}.uart")
        cmd = sim_cmd(a, f"{a.fw}/rom.hex", img,
                      [f"+bootarg={0x80000000 | test:08x}", f"+hostarg0={seed:x}", f"+hostarg1={iters:x}",
                       f"+hostarg2={flags:x}", f"+uart_log={ulog}", f"+timeout={timeout_ns}",
                       f"+cov={a.out}/cov_{name}.txt"])
        rc, out = run(cmd, os.path.join(a.out, f"{name}.log"), a.timeout)
        return {"name": name, "rc": rc, "out": out, "uart": ulog, "cmd": cmd, "seed": seed}

    jobs = [("drv", 2, 0, 0, 0)] + [(f"stress-s{s}", 1, s, a.dbg_iters, 0) for s in seeds] + \
           [("stress-repro", 1, seeds[0], a.dbg_iters, 0), ("crash-illegal", 3, 0, 0, 0),
            ("crash-misalign", 4, 0, 0, 0), ("hang", 5, 0, 0, 0), ("divtest", 6, 0, 0, 0)] + \
           [(f"inject-s{s}", 1, s, a.dbg_iters, 1) for s in inject] + \
           [("neg-stress-abort", 1, seeds[0], a.dbg_iters, 4), ("neg-drv-abort", 2, 0, 0, 4)]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        runs = {r["name"]: r for r in ex.map(lambda j: sim(*j), jobs)}
    res = []

    def rec(rid, ok, detail):
        print(f"  {'PASS' if ok else 'FAIL'} dbg/{rid:18s} {detail}")
        res.append({"id": f"dbg/{rid}", "status": "PASS" if ok else "FAIL", "detail": detail})

    r = runs["drv"]
    fails = re.findall(r"\[DBGT\] (.*?)\s+FAIL", r["out"])
    npass = len(re.findall(r"\[DBGT\] .* PASS", r["out"]))
    rec("drv", bench_ok(r["rc"], r["out"]) and "DBGTEST RESULT: PASS" in r["out"] and not fails and npass > 0,
        f"{npass} checks passed" + (f", failed: {fails}" if fails else ""))
    for s in seeds:
        r = runs[f"stress-s{s}"]
        rec(f"stress-s{s}", bench_ok(r["rc"], r["out"]) and f"STRESS PASS seed=0x{s:08x}" in r["out"]
            and not dbg_dumps(r["uart"]), f"seed {s}, {a.dbg_iters} iterations, exit {r['rc']}")

    def oplog(text):
        return [l for l in text.replace("\r", "").splitlines() if re.match(r"^(I \d+ op=|COV |STRESS )", l)]
    l1 = oplog(open(runs[f"stress-s{seeds[0]}"]["uart"], errors="replace").read())
    l2 = oplog(open(runs["stress-repro"]["uart"], errors="replace").read())
    rec("stress-repro", bool(l1) and l1 == l2 and bench_ok(runs["stress-repro"]["rc"], runs["stress-repro"]["out"]),
        f"seed {seeds[0]}: {len(l1)} operation / coverage lines, identical: {l1 == l2}")

    for name, cause, tval_check in (("crash-illegal", 2, False), ("crash-misalign", 4, True)):
        r = runs[name]
        d = dbg_dumps(r["uart"])
        ok = (bench_ok(r["rc"], r["out"]) and len(d) == 1 and d[0]["crc_ok"] and d[0]["reason"] == "exception"
              and d[0]["csr"].get("mcause") == cause and d[0]["errlog"].get("exc_cause") == cause
              and d[0]["errlog"].get("exc_pc") == d[0]["csr"].get("mepc")
              and (not tval_check or d[0]["csr"].get("mtval", 0) & 3 == 2))
        rec(name, ok, f"{len(d)} dump(s)" + (f", CRC {'ok' if d[0]['crc_ok'] else 'BAD'}, reason {d[0]['reason']}, "
                                              f"mcause {d[0]['csr'].get('mcause')}" if d else ""))
    r = runs["hang"]
    d = dbg_dumps(r["uart"])
    cov = open(f"{a.out}/cov_hang.txt", errors="replace").read() if os.path.exists(f"{a.out}/cov_hang.txt") else ""
    m = re.search(r"COV wdt resets (\d+)", cov)
    ok = (bench_ok(r["rc"], r["out"]) and "reset cause WATCHDOG" in r["out"] and len(d) == 1 and d[0]["crc_ok"]
          and d[0]["reason"] == "watchdog" and d[0]["errlog"].get("status", 0) & 0x18 == 0x18
          and d[0]["errlog"].get("wdt_cnt") == 1 and m is not None and int(m.group(1)) == 1
          and "DBGTEST hang detected by the watchdog: PASS" in r["out"])
    rec("hang", ok, f"PMU watchdog resets {m.group(1) if m else '?'}, {len(d)} post-mortem dump(s)"
        + (f", reason {d[0]['reason']}" if d else ""))

    r = runs["divtest"]
    d = dbg_dumps(r["uart"])
    km = re.search(r"DIVTEST kernel=0x([0-9a-f]+)", r["out"])
    det = "no dump / kernel address"
    ok = False
    if d and km and bench_ok(r["rc"], r["out"]):
        # Spike executes the same kernel at the same address (harness
        # fw/debug/spike_divk.S, linked with the kernel placed where the
        # debug application has it), with memory at the RAM window and the
        # trace buffer page (the kernel's final store)
        slog = os.path.join(a.out, "divtest_spike.log")
        selfp = os.path.join(a.out, "divtest_spike.elf")
        n = sum(1 for t in d[0]["trace"] if t["info"] & 3 == 0)
        kaddr = int(km.group(1), 16)
        cc = shutil.which(a.rv_prefix + "gcc") or a.rv_prefix + "gcc"
        lds = os.path.join(a.out, "divtest_spike.ld")
        with open(lds, "w") as f:
            f.write("ENTRY(_start)\nSECTIONS {\n"
                    f"  . = 0x{kaddr - 0x1000:x}; .start : {{ *(.text.start) }}\n"
                    f"  . = 0x{kaddr:x}; .kernel : {{ *(.text.dbg_div) }}\n"
                    "  . = 0x1001f000; .tohost : { *(.tohost) }\n}\n")
        try:
            bp = subprocess.run([cc, "-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
                                 "-I" + os.path.join(ROOT, "fw/include"), "-I" + os.path.join(ROOT, "fw/platform/lpsoc"),
                                 "-T", lds, "-Wl,--no-warn-rwx-segments",
                                 "-o", selfp, os.path.join(ROOT, "fw/debug/spike_divk.S"),
                                 os.path.join(ROOT, "fw/debug/dbg_div_kernel.S")],
                                capture_output=True, text=True, timeout=120)
            if bp.returncode:
                raise OSError("harness build failed: " + bp.stderr[-300:])
            p = subprocess.run([a.spike, "-l", f"--log={slog}", "--isa=rv32im_zicsr_zifencei",
                                "-m0x10001000:0x1f000,0x20008000:0x1000", selfp],
                               capture_output=True, text=True, timeout=120)
            dec = _tool("dbg_decode")
            dv = dec.divergence(d[0]["trace"], dec.parse_spike(open(slog, errors="replace").read()))
            ok = (d[0]["crc_ok"] and dv["status"] == "match" and dv.get("skipped", 0) == 0
                  and dv["matched"] == n and n >= 32)
            det = f"{n} retired in trace; Spike: {dv['detail']}"
        except (OSError, subprocess.TimeoutExpired) as e:
            det = f"Spike did not run: {e}"
    rec("divtest", ok, det)

    # negative tests (DBG_F_NEG_ABORT = 4): an aborted transition must fail the run
    r = runs["neg-stress-abort"]
    det = "STRESS CHECK FAILED: sleep transition ABORTED" in r["out"]
    res_ok = r["rc"] != 0 and "[tb] TEST FAILED" in r["out"] and det and "STRESS PASS" not in r["out"]
    print(f"  {'PASS' if res_ok else 'FAIL'} dbg-neg/stress-abort  "
          f"{'aborted sleep reported as a failure' if res_ok else 'NOT DETECTED: run did not fail on the aborted sleep'}")
    res.append({"id": "dbg-neg/stress-abort", "status": "PASS" if res_ok else "FAIL"})
    r = runs["neg-drv-abort"]
    det = re.search(r"\[DBGT\] SLEEP completed and resumed \(not ABORTED\)\s+FAIL", r["out"]) is not None
    res_ok = r["rc"] != 0 and "[tb] TEST FAILED" in r["out"] and det and "DBGTEST RESULT: FAIL" in r["out"]
    print(f"  {'PASS' if res_ok else 'FAIL'} dbg-neg/drv-abort     "
          f"{'aborted SLEEP reported as a failure' if res_ok else 'NOT DETECTED: driver test accepted the aborted SLEEP'}")
    res.append({"id": "dbg-neg/drv-abort", "status": "PASS" if res_ok else "FAIL"})

    # fault injection: each run must end in a crash dump (it is a failing run
    # by design); triage groups them by signature and must reproduce one
    os.makedirs(os.path.join(a.out, "inject"), exist_ok=True)
    tests = []
    for s in inject:
        r = runs[f"inject-s{s}"]
        d = dbg_dumps(r["uart"])
        crashed = r["rc"] != 0 and "INJECT kind=" in open(r["uart"], errors="replace").read()
        good = bool(d) and all(x["crc_ok"] for x in d) and d[-1]["reason"] in ("exception", "watchdog")
        rec(f"inject-s{s}", crashed and good,
            f"{'crashed' if crashed else 'did not crash'}, {len(d)} dump(s)" +
            (f", last reason {d[-1]['reason']}" if d else ""))
        shutil.copy(r["uart"], os.path.join(a.out, "inject", f"stress_s{s}.uart"))
        tests.append({"suite": "dbg", "name": "stress", "seed": s, "status": "FAIL" if r["rc"] else "PASS",
                      "cmd": r["cmd"], "cwd": ROOT, "artifacts": os.path.join(a.out, "inject"),
                      "log": os.path.join(a.out, f"inject-s{s}.log")})
    json.dump({"tests": tests}, open(os.path.join(a.out, "inject", "results.json"), "w"), indent=1)
    tri = _tool("triage")
    db = os.path.join(a.out, "inject", "seeds.json")
    trc, tout = run([PY, os.path.join(ROOT, "tools/triage.py"), os.path.join(a.out, "inject"), "--db", db],
                    os.path.join(a.out, "triage.log"), 600)
    groups = re.search(r"(\d+) failing, (\d+) signature group", tout)
    unknown = re.search(r"\b(unknown|timeout \(no crash dump\))\b", tout)
    rrc, rout = run([PY, os.path.join(ROOT, "tools/triage.py"), "--db", db, "--replay", str(inject[0]),
                     "--timeout", str(a.timeout)], os.path.join(a.out, "triage_replay.log"), a.timeout + 60)
    ok = (trc == 0 and groups is not None and int(groups.group(1)) == len(inject) and int(groups.group(2)) >= 1
          and not unknown and rrc == 0 and "REPRODUCED" in rout)
    rec("triage", ok, (f"{groups.group(1)} failing runs in {groups.group(2)} signature group(s)" if groups else
                       "no triage summary") + f"; replay of seed {inject[0]}: " +
        ("REPRODUCED" if "REPRODUCED" in rout else "not reproduced"))
    del tri
    save(a.out, res)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["suite", "spike", "monitor", "neg", "dbg"])
    ap.add_argument("--dbg-seeds", default="1 2 3 4", help="dbg: stress-test seeds")
    ap.add_argument("--dbg-inject-seeds", default="5 6", help="dbg: fault-injection seeds")
    ap.add_argument("--dbg-iters", type=int, default=24, help="dbg: stress iterations")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--rv-prefix", default="riscv64-unknown-elf-", help="dbg: cross compiler prefix (Spike harness)")
    ap.add_argument("--vl", default=os.path.join(ROOT, "build/sim/vl/Vtb_soc"))
    ap.add_argument("--fw", default=os.path.join(ROOT, "build/fw/lpsoc"))
    ap.add_argument("--spike", default=shutil.which("spike") or "/opt/spike/bin/spike")
    ap.add_argument("--elf", default=os.path.join(ROOT, "build/fw/spike/suite.elf"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=3600, help="wall-clock seconds per run")
    a = ap.parse_args()
    a.out = os.path.abspath(a.out)
    shutil.rmtree(a.out, ignore_errors=True)
    os.makedirs(a.out)
    {"suite": m_suite, "spike": m_spike, "monitor": m_monitor, "neg": m_neg, "dbg": m_dbg}[a.mode](a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
