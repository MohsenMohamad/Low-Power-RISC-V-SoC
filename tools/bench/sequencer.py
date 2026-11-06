#!/usr/bin/env python3
"""Lab test sequencer: runs a test list on a target through the monitor.

  tools/bench/sequencer.py tools/bench/testlists/sim_demo.toml --board sim
  tools/bench/sequencer.py <list> --board fpga-template --port /dev/ttyUSB1
  tools/bench/sequencer.py <list> --only "stress" --seed 1234     (replay)

Per step: firmware load (poke through the uncached RAM alias, read-back
CRC, watchdog reboot so the boot ROM checks the image), monitor commands,
forced power-state transitions and DVFS changes (the monitor's sleep / opp
commands and PMU register writes, checked in the PMU counters, the debug
event counters and the error log), debug tests (dbgrun), crash-dump capture. Every received line
is captured with a timestamp (uart_capture.log); each step's output is
saved as <step>_s<seed>.uart; results.json ({"tests": [...]}, the format
tools/triage.py reads) and results_check.json (id / status for
scripts/check_results.py, ids "bench/<step>").
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



class Bench:
    def __init__(self, prof, port, outdir):
        self.prof, self.out = prof, outdir
        self.cap = open(os.path.join(outdir, "uart_capture.log"), "w")
        self.t0 = time.time()
        self.step_lines = []
        self.mon = Monitor(port, capture=self._capture)
        self.dbg = sm.DBG_BASE

    def _capture(self, line, t):
        s = line.decode(errors="replace")
        self.cap.write("[%10.3f] %s\n" % (t - self.t0, s))
        self.cap.flush()
        self.step_lines.append(s)

    def dbg_rd(self, off):
        return self.mon.peek(self.dbg + off)



# ---------------------------------------------------------------- actions
def act_check_ids(b, st):
    """The four debug blocks answer with their exact IDs. The PMU has no ID
    register (doc/SOC_REGMAP.md); it is identified by registers with defined
    values: CTRL.LP_EN set (reset value, firmware never clears it), STATUS
    state RUN while the CPU executes this monitor, VSEL = STATUS.CUR_OP (an
    operating point 0..2), and the debug counters' PSTATE reporting RUN at the
    same operating point. A target answering 0 everywhere fails."""
    bad = []
    for off, exp in sm.DBG_IDS.items():
        v = b.dbg_rd(off)
        if v != exp:
            bad.append("debug 0x%08x=0x%08x (expected 0x%08x)" % (b.dbg + off, v, exp))
    ctrl = b.mon.peek(sm.PMU_BASE + sm.PMU["ctrl"])
    status = b.mon.peek(sm.PMU_BASE + sm.PMU["status"])
    vsel = b.mon.peek(sm.PMU_BASE + sm.PMU["vsel"])
    pstate = b.dbg_rd(sm.EVC["pstate"])
    cur_op = (status >> 8) & 3
    if not ctrl & sm.PMU_CTRL_LP_EN:
        bad.append("PMU CTRL=0x%08x: LP_EN clear" % ctrl)
    if status & 0x1F != 0:
        bad.append("PMU STATUS state %d, expected RUN (0)" % (status & 0x1F))
    if cur_op > 2 or vsel != cur_op:
        bad.append("PMU VSEL=%d CUR_OP=%d" % (vsel, cur_op))
    if pstate & 3 != sm.PS["run"] or (pstate >> 4) & 3 != cur_op:
        bad.append("debug PSTATE=0x%02x (expected RUN at OP%d)" % (pstate, cur_op))
    if bad:
        return False, "identity check failed: " + "; ".join(bad)
    return True, "debug IDs ok; PMU CTRL 0x%08x, STATUS 0x%08x (RUN, OP%d), VSEL %d; debug PSTATE 0x%02x" % (
        ctrl, status, cur_op, vsel, pstate)


def act_load(b, st):
    path = os.path.join(ROOT, st["image"])
    t = time.time()
    img = loader.load(b.mon, path, progress=lambda s: print(s, flush=True))
    msg = "loaded %s: %d bytes at 0x%08x (through the uncached alias), read-back CRC 0x%08x ok in %.0f s" % (
        os.path.basename(path), img["size"], img["load"], img["verified_crc"], time.time() - t)
    if st.get("start", "reboot") == "reboot":
        out = b.mon.reboot(timeout=b.prof.boot_timeout)        # boot ROM checks the header CRC
        cause = any("reset cause WATCHDOG" in ln for ln in out)
        ok = cause and any("image at 0x%08x" % img["load"] in ln for ln in out)
        return ok, msg + ("; watchdog reboot, boot ROM accepted the image" if ok else
                          "; boot ROM did not start the image: %r" % out[-4:])
    b.mon.go(img["entry"], timeout=b.prof.boot_timeout)
    return True, msg + "; started at 0x%08x" % img["entry"]


def act_invalidate_image(b, st):
    """Make the boot ROM fall back to its monitor on the next reboot."""
    b.mon.poke(sm.RAM_ALIAS + (sm.APP_BASE - sm.RAM_BASE), 0)
    out = b.mon.reboot(timeout=b.prof.boot_timeout)
    ok = any("no valid image" in ln for ln in out)
    return ok, "image header cleared; " + ("boot ROM monitor" if ok else "unexpected boot: %r" % out[-3:])


def act_info(b, st):
    out = b.mon.info()
    return True, " / ".join(out)[:150]


def power_counters(b):
    c = {k: b.dbg_rd(v) for k, v in list(sm.EVC.items()) + list(sm.ERR.items())}
    c["pmu_sleep_cnt"] = b.mon.peek(sm.PMU_BASE + sm.PMU["sleep_cnt"])
    c["pmu_idle_cnt"] = b.mon.peek(sm.PMU_BASE + sm.PMU["idle_cnt"])
    return c


def act_power(b, st):
    """Forced power-state transition: the monitor's 'sleep' arms the wake
    source and executes the WFI. The step passes only if the transition
    completed (result 0 for IDLE, 1 for SLEEP / DEEP_SLEEP; an aborted
    transition, result 2, is a failure, doc/SPEC.md) and every check holds -
    none is skipped: the PMU counter advanced by exactly one, the debug
    counters saw exactly two state changes (and one wake from SLEEP /
    DEEP_SLEEP, none from IDLE), the time spent in the state is at least half
    the requested ticks, and the error log's last transition is
    <state> -> RUN, result OK, two more transitions than before."""
    state, ticks = st["state"], st.get("ticks")
    want = 0 if state == "idle" else 1
    before = power_counters(b)
    r = b.mon.sleep(state, ticks, timeout=b.prof.cmd_timeout)
    after = power_counters(b)
    fails, info = [], []
    if r["result"] != want or r["error"]:
        fails.append("transition did not complete: result %d (%s)%s" % (
            r["result"], "ABORTED" if r["result"] == 2 else "expected %d" % want,
            ", monitor: " + r["error"] if r["error"] else ""))
    pmu_key = "pmu_idle_cnt" if state == "idle" else "pmu_sleep_cnt"
    if after[pmu_key] != before[pmu_key] + 1:
        fails.append("PMU %s %d -> %d (expected +1)" % (pmu_key[4:], before[pmu_key], after[pmu_key]))
    if after["trans"] != before["trans"] + 2:
        fails.append("debug transitions %d -> %d (expected +2)" % (before["trans"], after["trans"]))
    want_wake = 0 if state == "idle" else 1
    if after["wake"] != before["wake"] + want_wake:
        fails.append("debug wake count %d -> %d (expected +%d)" % (before["wake"], after["wake"], want_wake))
    tkey = {"idle": "t_idle_lo", "sleep": "t_sleep_lo", "deep": "t_dsleep_lo"}[state]
    dt = (after[tkey] - before[tkey]) & 0xFFFFFFFF
    if dt == 0 or (ticks is not None and dt < ticks // 2):
        fails.append("time in %s +%d clk_aon cycles (expected >= %d)" % (state, dt, (ticks or 2) // 2))
    last, n0 = after["pwr_last"], before["pwr_last"] >> 16
    if (last & 3) != sm.PS[state] or ((last >> 2) & 3) != sm.PS["run"] or ((last >> 4) & 3) != sm.RES_OK \
            or (last >> 16) != n0 + 2:
        fails.append("error log last transition 0x%08x (expected %s -> RUN OK, count %d)" % (last, state, n0 + 2))
    info.append("result %d, %s +%d, transitions +%d, wakes +%d, time in %s +%d cycles, errlog 0x%08x" % (
        r["result"], pmu_key[4:], after[pmu_key] - before[pmu_key], after["trans"] - before["trans"],
        after["wake"] - before["wake"], state, dt, last))
    return not fails, "sleep %s: " % state + ("; ".join(fails) if fails else "; ".join(info))


def act_dvfs(b, st):
    """DVFS change: the bench writes the PMU's TARGET_OP register (poke), the
    monitor's 'opp' executes the WFI so the PMU switches while the clock is
    gated; checked in PMU STATUS.CUR_OP / VSEL and the debug DVFS count."""
    op = st["op"]
    before = power_counters(b)
    cur0 = (b.mon.peek(sm.PMU_BASE + sm.PMU["status"]) >> 8) & 3
    b.mon.poke(sm.PMU_BASE + sm.PMU["dvfs"], op)                   # target point (register write)
    b.mon.opp(op, timeout=b.prof.cmd_timeout)
    cur = (b.mon.peek(sm.PMU_BASE + sm.PMU["status"]) >> 8) & 3
    vsel = b.mon.peek(sm.PMU_BASE + sm.PMU["vsel"])
    after = power_counters(b)
    changed = after["dvfs"] - before["dvfs"]
    ok = cur == op and vsel == op and changed == (0 if cur0 == op else 1) and (after["pstate"] >> 4) & 3 == op
    return ok, "OP%d -> OP%d: PMU CUR_OP=%d VSEL=%d, debug DVFS count +%d, PSTATE 0x%02x" % (
        cur0, op, cur, vsel, changed, after["pstate"])


def act_run(b, st):
    v, res, _out = b.mon.run_test(st["test"], timeout=b.prof.cmd_timeout)
    return v == "PASS", "run %s: %s (%s)" % (st["test"], v, ", ".join("%d %s" % (i, r) for i, _n, r in res))


def act_dbgrun(b, st):
    v, out = b.mon.dbgrun(st["test"], st["seed"], st.get("iters", 0), st.get("flags", 0),
                          timeout=b.prof.cmd_timeout)
    text = "\n".join(b.step_lines)
    try:
        dumps = [d for d in dbg_decode.parse_dumps(text) if d["reason"] != "request"]
    except dbg_decode.DumpError as ex:
        return False, "corrupt crash dump: %s" % ex
    if st.get("expect") == "crash":
        ok = v == "PASS" and bool(dumps) and dumps[-1]["crc_ok"] and \
            dumps[-1]["csr"].get("mcause") == st.get("mcause", dumps[-1]["csr"].get("mcause"))
        sig = dbg_decode.signature(dumps[-1]) if dumps else {}
        if dumps:      # after a crash only the base monitor runs: reboot the image
            b.mon.reboot(timeout=b.prof.boot_timeout)
        return ok, "expected crash captured: %s" % json.dumps(sig) if ok else "no valid expected crash: %s" % (
            json.dumps(sig) if sig else "no dump")
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
    ap.add_argument("--sim-timeout-ns", type=int, default=60_000_000_000, help="sim: simulated-time limit")
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
        sim = sim_bridge.SimTarget(os.path.join(a.out, "sim"), timeout_ns=a.sim_timeout_ns)
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
                if sim and not sim.alive():
                    status, detail = "TIMEOUT", detail + " (simulation ended: %s)" % sim.last_words()
                else:
                    try:
                        b.mon.sync(timeout=prof.cmd_timeout)
                    except (MonitorError, OSError):
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
    # one result per step for scripts/check_results.py (dv/regress/bench.required)
    json.dump([{"id": "bench/%s" % r["name"], "status": r["status"], "detail": r["detail"]} for r in results],
              open(os.path.join(a.out, "results_check.json"), "w"), indent=1)
    print("BENCH %s: %d steps, %d failed; capture %s" % ("PASS" if n_fail == 0 else "FAIL", len(results), n_fail,
                                                         os.path.join(a.out, "uart_capture.log")))
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
