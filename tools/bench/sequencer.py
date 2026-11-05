#!/usr/bin/env python3
"""Lab test sequencer: runs a test list on a target through the monitor.

  tools/bench/sequencer.py tools/bench/testlists/sim_demo.toml --board sim
  tools/bench/sequencer.py <list> --board fpga-template --port /dev/ttyUSB1
  tools/bench/sequencer.py <list> --only "stress" --seed 1234     (replay)

Per step: firmware load (poke + read-back CRC), monitor commands, forced
power-state transitions and DVFS changes (PMU register writes + the
monitor's sleep / opp commands, checked against the debug counters and the
error log), debug tests (dbgrun), crash-dump capture. Every received line
is captured with a timestamp (uart_capture.log); each step's output is
saved as <step>_s<seed>.uart; results.json has the format of
tools/regress.py so tools/triage.py groups the failures.
"""
import argparse
import json
import os
import re
import sys
import time
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import board as boards          # noqa: E402
import loader                   # noqa: E402
import soc_map as sm            # noqa: E402
from monitor_adapter import Monitor, MonitorError   # noqa: E402
import dbg_decode               # noqa: E402

PS = {"idle": 1, "sleep": 2, "deep": 3}


class Bench:
    def __init__(self, prof, port, outdir):
        self.prof, self.out = prof, outdir
        self.cap = open(os.path.join(outdir, "uart_capture.log"), "w")
        self.t0 = time.time()
        self.step_lines = []
        self.mon = Monitor(port, capture=self._capture)
        self.dbg = prof.dbg_base

    def _capture(self, line, t):
        s = line.decode(errors="replace")
        self.cap.write("[%10.3f] %s\n" % (t - self.t0, s))
        self.cap.flush()
        self.step_lines.append(s)

    def dbg_rd(self, off):
        return self.mon.peek(self.dbg + off)

    def counters(self):
        return {k: self.dbg_rd(v) for k, v in list(sm.EVC.items()) + list(sm.ERR.items())}


# ---------------------------------------------------------------- actions
def act_check_ids(b, st):
    bad = []
    for off, exp in sm.DBG_IDS.items():
        v = b.dbg_rd(off)
        if v != exp:
            bad.append("0x%08x=0x%08x" % (b.dbg + off, v))
    pmu = b.mon.peek(sm.PMU_BASE + sm.PMU["id"])
    return not bad, "debug IDs ok, PMU id 0x%08x" % pmu if not bad else "bad IDs: " + ", ".join(bad)


def act_load(b, st):
    path = os.path.join(ROOT, st["image"])
    t = time.time()
    img = loader.load(b.mon, path, progress=lambda s: print(s, flush=True))
    msg = "loaded %s: %d bytes at 0x%08x, read-back CRC 0x%08x ok in %.0f s" % (
        os.path.basename(path), img["size"], img["load"], img["verified_crc"], time.time() - t)
    if st.get("start", "reset") == "reset":
        out = b.mon.reset(timeout=b.prof.boot_timeout)          # boot ROM checks the header CRC
        ok = any("image at" in ln for ln in out)
        return ok, msg + "; boot ROM accepted the image" if ok else msg + "; boot ROM rejected it: %r" % out[-3:]
    b.mon.go(img["entry"], timeout=b.prof.boot_timeout)
    return True, msg + "; started at 0x%08x" % img["entry"]


def act_invalidate_image(b, st):
    """Make the boot ROM fall back to its monitor on the next reset."""
    b.mon.poke(sm.APP_BASE, 0)
    out = b.mon.reset(timeout=b.prof.boot_timeout)
    return True, "image header cleared; " + (out[-1] if out else "")


def act_info(b, st):
    out = b.mon.info()
    return True, " / ".join(out)[:150]


def act_power(b, st):
    """Forced power-state transition: PMU wake source configured by register
    write, the monitor's 'sleep' executes the WFI; the transition is checked
    in the PMU counters, the debug event counters and the error log."""
    state, ticks = st["state"], st.get("ticks")
    before = b.counters()
    pmu_cnt = {"idle": "cnt_idle", "sleep": "cnt_sleep", "deep": "cnt_deep"}[state]
    pmu_before = b.mon.peek(sm.PMU_BASE + sm.PMU[pmu_cnt])
    b.mon.poke(sm.PMU_BASE + sm.PMU["wake_en"], 1)                 # MTIP (register write)
    r = b.mon.sleep(state, ticks, timeout=b.prof.cmd_timeout)
    after = b.counters()
    pmu_after = b.mon.peek(sm.PMU_BASE + sm.PMU[pmu_cnt])
    checks = []
    ok = r["result"] in (0, 1, 2)
    if r["result"] == 2:
        checks.append("aborted by pending wake")
    else:
        ok &= pmu_after == pmu_before + 1
        ok &= after["trans"] >= before["trans"] + 2
        if state in ("sleep", "deep"):
            ok &= after["wake"] == before["wake"] + 1
            key = "t_sleep_lo" if state == "sleep" else "t_dsleep_lo"
            ok &= after[key] > before[key]
            checks.append("wake count %d->%d, time in %s +%d cycles" % (
                before["wake"], after["wake"], state, after[key] - before[key]))
        last = after["pwr_last"]
        checks.append("errlog last transition %s->%s result %d" % (last & 3, (last >> 2) & 3, (last >> 4) & 3))
    return ok, "sleep %s: result %d, off_time %d; PMU %s %d->%d; %s" % (
        state, r["result"], r["off_time"], pmu_cnt, pmu_before, pmu_after, "; ".join(checks))


def act_dvfs(b, st):
    op = st["op"]
    before = b.counters()
    b.mon.poke(sm.PMU_BASE + sm.PMU["dvfs_op"], op)                # target point (register write)
    b.mon.opp(op, timeout=b.prof.cmd_timeout)                      # WFI: PMU switches while gated
    cur = b.mon.peek(sm.PMU_BASE + sm.PMU["status"]) & 3
    after = b.counters()
    changed = after["dvfs"] - before["dvfs"]
    ok = cur == op and (changed >= 1 or (before["pstate"] >> 4) & 3 == op)
    return ok, "OP%d: PMU CUR_OP=%d, debug DVFS count %d->%d, PSTATE 0x%02x" % (
        op, cur, before["dvfs"], after["dvfs"], after["pstate"])


def act_run(b, st):
    v, res, _out = b.mon.run_test(st["test"], timeout=b.prof.cmd_timeout)
    return v == "PASS", "run %s: %s (%s)" % (st["test"], v, ", ".join("%d %s" % (i, r) for i, _n, r in res))


def act_dbgrun(b, st):
    v, out = b.mon.dbgrun(st["test"], st["seed"], st.get("iters", 0), st.get("flags", 0),
                          timeout=b.prof.cmd_timeout)
    text = "\n".join(b.step_lines)
    dumps = []
    try:
        dumps = [d for d in dbg_decode.parse_dumps(text) if d["reason"] != "request"]
    except dbg_decode.DumpError as ex:
        return False, "corrupt crash dump: %s" % ex
    if st.get("expect") == "crash":
        ok = bool(dumps) and dumps[-1]["crc_ok"]
        sig = dbg_decode.signature(dumps[-1]) if dumps else {}
        if ok:   # back to a full monitor: reboot the image (post-mortem dump at boot)
            b.mon.reset(timeout=b.prof.boot_timeout)
        return ok, "expected crash captured: %s" % json.dumps(sig) if ok else "no valid crash dump"
    if dumps:
        return False, "unexpected crash: %s" % json.dumps(dbg_decode.signature(dumps[-1]))
    return v == "PASS", "dbgrun %d seed %d: %s" % (st["test"], st["seed"], v)


def act_dump(b, st):
    b.mon.dbg_dump(timeout=b.prof.cmd_timeout)
    d = dbg_decode.parse_dumps("\n".join(b.step_lines))
    ok = bool(d) and d[-1]["crc_ok"]
    return ok, "debug dump: %d trace entries, CRC %s" % (len(d[-1]["trace"]) if d else 0, "ok" if ok else "bad")


ACTIONS = {"check_ids": act_check_ids, "load": act_load, "invalidate_image": act_invalidate_image,
           "info": act_info, "power": act_power, "dvfs": act_dvfs, "run": act_run, "dbgrun": act_dbgrun,
           "dump": act_dump}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("testlist")
    ap.add_argument("--board", default="sim", choices=sorted(boards.PROFILES))
    ap.add_argument("--port", help="override the board's serial port")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "bench"))
    ap.add_argument("--only", help="regex: run only matching steps (load steps always run)")
    ap.add_argument("--seed", type=int, help="override the seed of dbgrun steps (replay)")
    a = ap.parse_args(argv)
    tl = tomllib.load(open(a.testlist, "rb"))
    prof = boards.PROFILES[a.board]
    a.out = os.path.abspath(a.out)
    os.makedirs(a.out, exist_ok=True)
    art = os.path.join(a.out, "artifacts")
    os.makedirs(art, exist_ok=True)

    sim = None
    if a.board == "sim":
        import sim_bridge
        sim = sim_bridge.SimTarget(os.path.join(a.out, "sim"))
        prof.port = sim.port
        print("simulation UART on %s (sim log %s)" % (sim.port, sim.log), flush=True)
    elif a.port:
        prof.port = a.port
    prof.program()
    prof.reset()
    port = prof.open_port()
    b = Bench(prof, port, a.out)
    results = []
    try:
        b.mon.sync(timeout=prof.boot_timeout)
        for i, st in enumerate(tl["step"]):
            name = st.get("name", "%02d-%s" % (i, st["action"]))
            if a.only and not re.search(a.only, name) and st["action"] not in ("load", "invalidate_image"):
                continue
            if a.seed is not None and "seed" in st:
                st = dict(st, seed=a.seed)
            seed = st.get("seed")
            b.step_lines = []
            t = time.time()
            try:
                ok, detail = ACTIONS[st["action"]](b, st)
                status = "PASS" if ok else "FAIL"
            except (MonitorError, loader.LoadError, OSError) as ex:
                status, detail = "FAIL", "%s: %s" % (type(ex).__name__, str(ex)[:200])
                try:
                    b.mon.sync(timeout=prof.cmd_timeout)
                except MonitorError:
                    status, detail = "TIMEOUT", detail + " (target not responding)"
            dt = time.time() - t
            safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
            fn = os.path.join(art, "%s_s%s.uart" % (safe, seed if seed is not None else 0))
            open(fn, "w").write("\n".join(b.step_lines) + "\n")
            cmd = [sys.executable, os.path.abspath(__file__), os.path.abspath(a.testlist), "--board", a.board,
                   "--only", "^%s$" % re.escape(name)] + (["--seed", str(seed)] if seed is not None else [])
            results.append({"suite": "bench-" + tl.get("run", {}).get("name", "lab"), "name": safe, "seed": seed,
                            "status": status, "runtime": dt, "detail": detail, "log": fn, "cmd": cmd, "cwd": ROOT,
                            "artifacts": art})
            print("%-7s %-34s %6.1fs  %s" % (status, name, dt, detail), flush=True)
            if status == "TIMEOUT":
                break
    finally:
        port.close()
        if sim:
            sim.stop()
    n_fail = sum(r["status"] != "PASS" for r in results)
    json.dump({"tests": results}, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    print("BENCH %s: %d steps, %d failed; capture %s" % ("PASS" if n_fail == 0 else "FAIL", len(results), n_fail,
                                                         os.path.join(a.out, "uart_capture.log")))
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
