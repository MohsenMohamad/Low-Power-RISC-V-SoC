#!/usr/bin/env python3
"""Decode a UART crash dump (doc/DEBUG_SPEC.md section 10) into a report.

  dbg_decode.py <uart log>                     readable report of every dump
  dbg_decode.py <uart log> --json out.json     machine-readable (used by triage)
  dbg_decode.py <uart log> --spike-log s.log   first point of divergence between
                                               the dumped trace and a Spike log
                                               (spike -l or --log-commits)
  dbg_decode.py <uart log> --elf app.elf       add symbol names (nm)

Exit status: 0 ok, 1 no dump / CRC error, 2 divergence found.
"""
import argparse
import binascii
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_disasm import disasm  # noqa: E402

PSTATE = ["RUN", "IDLE", "SLEEP", "DEEP_SLEEP"]
PWR_RESULT = ["OK", "timeout", "aborted", "sequencing-error"]
ERR_BITS = ["EXC", "EXC_OVR", "PWR_ERR", "WDT_BITE", "WDT_RST", "SW_ERR"]
TRC_BITS = ["ACTIVE", "FROZEN", "WRAPPED", "STOPPED", "ARMED", "CLR_PEND", "OVF"]
EXC_NAMES = {0: "instruction address misaligned", 1: "instruction access fault", 2: "illegal instruction",
             3: "breakpoint", 4: "load address misaligned", 5: "load access fault",
             6: "store address misaligned", 7: "store access fault", 8: "ecall U", 11: "ecall M"}
IRQ_NAMES = {3: "machine software interrupt", 7: "machine timer interrupt", 11: "machine external interrupt"}
TYPE_NAMES = ["retire", "trap", "power", "?"]

KV_RE = re.compile(r"(\w+)=(0x[0-9a-fA-F]+|\d+)")


class DumpError(Exception):
    pass


def cause_str(c):
    if c & 0x80000000:
        return "interrupt %d (%s)" % (c & 0x7FFFFFFF, IRQ_NAMES.get(c & 0x7FFFFFFF, "?"))
    return "exception %d (%s)" % (c, EXC_NAMES.get(c, "?"))


def bits_str(v, names):
    s = [n for i, n in enumerate(names) if v >> i & 1]
    return "|".join(s) if s else "-"


def pwr_str(v):
    if v == 0:
        return "none"
    return "%s -> %s: %s (%d transitions)" % (PSTATE[v & 3], PSTATE[(v >> 2) & 3], PWR_RESULT[(v >> 4) & 3],
                                             v >> 16)


def parse_dumps(text):
    """Return a list of dump dicts found in text (CRC verified)."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    dumps = []
    pos = 0
    while True:
        b = text.find("### DBG-CRASH BEGIN", pos)
        if b < 0:
            break
        e = text.find("### DBG-CRASH END", b)
        if e < 0:
            raise DumpError("dump at offset %d has no END line (truncated)" % b)
        eol = text.find("\n", e)
        end_line = text[e:eol if eol >= 0 else len(text)]
        body = text[b:e]
        pos = e + 1
        m = re.search(r"crc=0x([0-9a-fA-F]+)", end_line)
        crc_ok = m is not None and (binascii.crc32(body.encode()) & 0xFFFFFFFF) == int(m.group(1), 16)
        d = {"crc_ok": crc_ok, "trace": [], "offset": b}
        for line in body.split("\n"):
            if line.startswith("REASON "):
                d["reason"] = line.split(" ", 1)[1].strip()
            elif line.startswith("SEED "):
                d["seed"] = int(line.split()[1], 16)
            elif line.startswith(("CSR ", "ERRLOG ", "COUNTERS ", "TRACE ")):
                key = {"CSR": "csr", "ERRLOG": "errlog", "COUNTERS": "counters",
                       "TRACE": "trace_status"}[line.split(" ", 1)[0]]
                d[key] = {k: int(v, 0) for k, v in KV_RE.findall(line)}
            elif line.startswith("T "):
                kv = {k: int(v, 0) for k, v in KV_RE.findall(line)}
                kv["idx"] = int(line.split()[1])
                d["trace"].append(kv)
        for k in ("reason", "csr", "errlog", "counters", "trace_status"):
            if k not in d:
                raise DumpError("dump at offset %d lacks %s" % (b, k))
        dumps.append(d)
    return dumps


def signature(d):
    """Failure signature used by triage: reason, cause, PC, power state, watchdog."""
    e, c = d["errlog"], d["csr"]
    cause = c.get("mcause") or (e.get("exc_cause") if e.get("status", 0) & 1 else 0)
    pc = c.get("mepc") or (e.get("exc_pc") if e.get("status", 0) & 1 else 0)
    if not pc and d["trace"]:
        pc = [t for t in d["trace"] if t["info"] & 3 == 0][-1:][0]["pc"] if any(
            t["info"] & 3 == 0 for t in d["trace"]) else 0
    last_ps = (e.get("pwr_last", 0) >> 2) & 3
    wdt = bool(e.get("status", 0) & 0x18)
    if wdt and not c.get("mcause"):
        # a hang is a loop: identify it by its lowest PC among the last
        # retired instructions, not by wherever the bite happened to land
        tail = [t["pc"] for t in d["trace"] if t["info"] & 3 == 0][-8:]
        if tail:
            pc = min(tail)
    return {"reason": d["reason"], "cause": cause, "pc": pc, "pstate": PSTATE[last_ps], "watchdog": wdt}


def load_symbols(elf):
    nm = shutil.which("riscv64-unknown-elf-nm") or shutil.which("llvm-nm") or shutil.which("nm")
    if not nm or not elf:
        return []
    try:
        out = subprocess.run([nm, "-n", elf], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    syms = []
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[1] in "tTwW":
            syms.append((int(p[0], 16), p[2]))
    return syms


def sym_of(syms, pc):
    best = None
    for a, n in syms:
        if a <= pc:
            best = (a, n)
        else:
            break
    return "%s+0x%x" % (best[1], pc - best[0]) if best else ""


def report(d, syms=()):
    out = []
    w = out.append
    e, c, k = d["errlog"], d["csr"], d["counters"]
    w("=" * 78)
    w("Crash dump: reason=%s seed=0x%08x  CRC %s" % (d["reason"], d.get("seed", 0), "OK" if d["crc_ok"] else "MISMATCH"))
    w("-" * 78)
    w("CPU   mcause   0x%08x  %s" % (c.get("mcause", 0), cause_str(c.get("mcause", 0)) if c.get("mcause") else "(no trap frame)"))
    w("      mepc     0x%08x  %s" % (c.get("mepc", 0), sym_of(syms, c.get("mepc", 0))))
    w("      mtval    0x%08x   mstatus 0x%08x" % (c.get("mtval", 0), c.get("mstatus", 0)))
    w("      mcycle   %d   minstret %d" % (c.get("mcycle", 0), c.get("minstret", 0)))
    w("Error log  status 0x%02x [%s]" % (e.get("status", 0), bits_str(e.get("status", 0), ERR_BITS)))
    if e.get("exc_cnt"):
        w("  last exception: %s at pc 0x%08x %s tval 0x%08x (ts %d, %d seen)" % (
            cause_str(e["exc_cause"]), e["exc_pc"], sym_of(syms, e["exc_pc"]), e["exc_tval"], e["exc_ts"], e["exc_cnt"]))
    w("  last power transition: %s (ts %d)" % (pwr_str(e.get("pwr_last", 0)), e.get("pwr_ts", 0)))
    if e.get("pwr_err_last"):
        w("  last FAILED power transition: %s" % pwr_str(e["pwr_err_last"]))
    if e.get("wdt_cnt"):
        w("  watchdog bites: %d, last at ts %d in %s" % (e["wdt_cnt"], e["wdt_ts"], PSTATE[e.get("wdt_pstate", 0) & 3]))
    if e.get("status", 0) & 0x20:
        w("  software error code 0x%08x" % e.get("sw_code", 0))
    w("Counters  I$ hit/miss %d/%d  D$ hit/miss %d/%d  stall %d" % (
        k.get("ic_hit", 0), k.get("ic_miss", 0), k.get("dc_hit", 0), k.get("dc_miss", 0), k.get("stall", 0)))
    ic = k.get("ic_hit", 0) + k.get("ic_miss", 0)
    dc = k.get("dc_hit", 0) + k.get("dc_miss", 0)
    if ic or dc:
        w("          I$ hit rate %.1f%%  D$ hit rate %.1f%%" % (100.0 * k.get("ic_hit", 0) / max(ic, 1),
                                                             100.0 * k.get("dc_hit", 0) / max(dc, 1)))
    w("          wakes %d  DVFS changes %d  power transitions %d  now %s / OP%d" % (
        k.get("wake", 0), k.get("dvfs", 0), k.get("trans", 0), PSTATE[k.get("pstate", 0) & 3], (k.get("pstate", 0) >> 4) & 3))
    w("          clk_aon cycles in RUN %d  IDLE %d  SLEEP %d  DEEP_SLEEP %d" % (
        k.get("t_run", 0), k.get("t_idle", 0), k.get("t_sleep", 0), k.get("t_dsleep", 0)))
    ti = d.get("trace_status", {})
    w("Trace  status 0x%02x [%s]  %d entries (oldest first), %d written in total" % (
        ti.get("status", 0), bits_str(ti.get("status", 0), TRC_BITS), ti.get("count", 0), ti.get("total", 0)))
    prev_ts = None
    for x in d["trace"]:
        typ = x["info"] & 3
        dts = "" if prev_ts is None else "+%d" % (x["ts"] - prev_ts)
        prev_ts = x["ts"]
        if typ == 0:
            text = disasm(x["data"], x["pc"])
            w("  %3d  %08x  %08x  %-34s %-26s ts %d %s" % (x["idx"], x["pc"], x["data"], text, sym_of(syms, x["pc"]), x["ts"], dts))
        elif typ == 1:
            cause = ((x["info"] >> 16) & 0xFF) | (x["info"] & 0x80000000)
            w("  %3d  %08x  TRAP %s tval 0x%08x  ts %d %s" % (x["idx"], x["pc"], cause_str(cause), x["data"], x["ts"], dts))
        else:
            w("  %3d  ---------  POWER -> %s  ts %d %s" % (x["idx"], PSTATE[(x["info"] >> 2) & 3], x["ts"], dts))
    w("Signature: %s" % json.dumps(signature(d)))
    return "\n".join(out)


# ---------------------------------------------------------------- Spike log
SPIKE_RE = re.compile(r"core\s+\d+:\s+(?:\d\s+)?0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)")


def parse_spike(text):
    """(pc, insn) for every executed instruction of a Spike -l / --log-commits log."""
    seq = []
    for line in text.splitlines():
        m = SPIKE_RE.search(line)
        if m:
            seq.append((int(m.group(1), 16) & 0xFFFFFFFF, int(m.group(2), 16) & 0xFFFFFFFF))
    return seq


def divergence(trace, spike):
    """Align the retired-instruction trace with the Spike sequence and report
    the first entry that differs. Returns dict."""
    dut = [(x["pc"], x["data"], x["idx"]) for x in trace if x["info"] & 3 == 0]
    if not dut:
        return {"status": "empty", "detail": "trace holds no retired instructions"}
    best = (-1, None)
    # Align on the PC sequence only (an instruction-word mismatch must not
    # move the alignment): candidates are Spike positions whose PC equals one
    # of the first trace PCs (the trace may start in the middle of a loop).
    for k0 in range(min(8, len(dut))):
        for s in (i for i, (pc, _) in enumerate(spike) if pc == dut[k0][0]):
            n = 0
            while k0 + n < len(dut) and s + n < len(spike) and spike[s + n][0] == dut[k0 + n][0]:
                n += 1
            if n > best[0]:
                best = (n, (k0, s))
        if best[0] >= len(dut) - k0:
            break
    if best[1] is not None:
        # first difference in PC or instruction word inside the aligned window
        n_pc, (k0, s) = best
        n = 0
        while n < n_pc and spike[s + n][1] == dut[k0 + n][1]:
            n += 1
        best = (n, (k0, s))
    if best[1] is None:
        return {"status": "no-alignment", "detail": "trace PCs do not occur in the Spike log"}
    n, (k0, s) = best
    if k0 + n >= len(dut):
        return {"status": "match", "matched": n, "skipped": k0,
                "detail": "no divergence: %d retired instructions match Spike (from trace entry %d)" % (n, dut[k0][2])}
    i = k0 + n
    d_pc, d_insn, idx = dut[i]
    if s + n < len(spike):
        s_pc, s_insn = spike[s + n]
    else:
        s_pc, s_insn = None, None
    res = {"status": "diverged", "matched": n, "trace_index": idx, "dut_pc": d_pc, "dut_insn": d_insn,
           "spike_pc": s_pc, "spike_insn": s_insn}
    if s_pc is None:
        res["detail"] = "Spike log ends after %d matching instructions (trace entry %d)" % (n, idx)
    else:
        res["detail"] = ("first divergence at trace entry %d after %d matching instructions:\n"
                         "  DUT   pc 0x%08x  0x%08x  %s\n  Spike pc 0x%08x  0x%08x  %s" % (
                             idx, n, d_pc, d_insn, disasm(d_insn, d_pc), s_pc, s_insn, disasm(s_insn, s_pc)))
    return res


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("log", help="UART log containing the dump(s)")
    p.add_argument("--json", help="write decoded dumps as JSON")
    p.add_argument("--spike-log", help="Spike execution log (-l or --log-commits)")
    p.add_argument("--elf", help="ELF for symbol names")
    p.add_argument("--index", type=int, default=-1, help="which dump to use with --spike-log (default last)")
    a = p.parse_args(argv)
    try:
        text = open(a.log, errors="replace").read()
        dumps = parse_dumps(text)
    except (OSError, DumpError) as ex:
        print("error: %s" % ex)
        return 1
    if not dumps:
        print("no crash dump found in %s" % a.log)
        return 1
    syms = load_symbols(a.elf)
    rc = 0
    for d in dumps:
        print(report(d, syms))
        if not d["crc_ok"]:
            rc = 1
    if a.spike_log:
        spike = parse_spike(open(a.spike_log, errors="replace").read())
        res = divergence(dumps[a.index]["trace"], spike)
        print("-" * 78)
        print("Spike comparison (%d Spike instructions): %s" % (len(spike), res["detail"]))
        dumps[a.index]["spike"] = res
        if res["status"] == "diverged":
            rc = max(rc, 2)
        elif res["status"] != "match":
            rc = max(rc, 1)
    if a.json:
        for d in dumps:
            d["signature"] = signature(d)
        with open(a.json, "w") as f:
            json.dump(dumps, f, indent=1)
    return rc


if __name__ == "__main__":
    sys.exit(main())
