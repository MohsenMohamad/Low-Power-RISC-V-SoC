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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["suite", "spike", "monitor", "neg"])
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
    {"suite": m_suite, "spike": m_spike, "monitor": m_monitor, "neg": m_neg}[a.mode](a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
