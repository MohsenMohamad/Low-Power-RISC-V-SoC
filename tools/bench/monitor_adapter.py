"""Protocol adapter for the UART bring-up monitor of main's firmware
(fw/app/monitor.c, fw/app/main.c, fw/app/app_cmds.c, fw/debug/dbg_app.c).

This is the only bench module that knows the monitor protocol:

  prompt "mon> " after every command; "zzz> " before a UART-wake sleep
  input echoed character by character, line ends with \\r or \\n
  output lines end with \\r\\n; errors start with "ERR"
  peek <addr|blk.reg> [n]   -> "0x%08x: 0x%08x" per word (n <= 256); a fault
                               is "ERR fault 0x<addr>"
  poke <addr|blk.reg> <v>   -> "OK" (a RAM address also cleans the D-cache)
  regs <block>              -> "blk.name 0xaddr: 0xvalue" lines
  go <addr>                 -> "jumping to 0x%08x", then the code runs
  run <id|all>              -> "[TEST n] name PASS|FAIL|SKIP" ...       (validation app)
  info / list               -> free text                                (validation app)
  sleep <idle|sleep|deep> <ticks|uart>
                            -> "woke: result r, rst_cause c, wake_cause w, sleep_cnt +n";
                               a transition that did not complete adds
                               "ERR transition ABORTED|failed"
  opp <0..2>                -> "opp n"
  exit [code]               -> "PASS" / "FAIL 0x..." (end of a simulation)
Debug application (fw/debug/dbg_app.c):
  dbg                       -> crash-format dump (reason "request")
  dbgrun <t> <seed> [iters] [flags] -> test output, "DBGRUN RESULT: PASS|FAIL"

There is no reset, load or checksum command: images are written with poke
through the RAM's uncached alias and verified by peek read-back plus a
host-side CRC (tools/bench/loader.py); a reboot is a watchdog reset of
PD_CPU (reboot(), doc/SOC_REGMAP.md "Watchdog reset"), after which the boot
ROM checks the image header CRC before it starts the image.
"""
import re
import time

import soc_map as sm

PROMPT = b"mon> "
WAKE_PROMPT = b"zzz> "
PEEK_RE = re.compile(r"^0x([0-9a-fA-F]{8}): 0x([0-9a-fA-F]{8})$")
TEST_RE = re.compile(r"^\[TEST +(\d+)\] +(\S+) +(PASS|FAIL|SKIP)")
WOKE_RE = re.compile(r"woke: result (-?\d+), rst_cause (\d+), wake_cause (\d+), sleep_cnt \+(\d+)")
ROM_BANNER = b"[ROM] LPSOC boot ROM"


class MonitorError(Exception):
    pass


class Monitor:
    """Command/response layer on a byte port (pyserial Serial or compatible).

    capture: optional callable(line_bytes, t) receiving every complete line
    received from the target with a timestamp (lab log)."""

    def __init__(self, port, capture=None):
        self.port = port
        self.capture = capture
        self.buf = b""

    # ---------------- low level ----------------
    def _log(self, data):
        if not self.capture:
            return
        self._cap = getattr(self, "_cap", b"") + data
        while b"\n" in self._cap:
            line, self._cap = self._cap.split(b"\n", 1)
            self.capture(line.rstrip(b"\r"), time.time())

    def read_until(self, tokens, timeout):
        """Read until one of tokens appears; return (text_before, token)."""
        t_end = time.time() + timeout
        while True:
            for tok in tokens:
                i = self.buf.find(tok)
                if i >= 0:
                    out = self.buf[:i]
                    self.buf = self.buf[i + len(tok):]
                    return out.decode(errors="replace"), tok
            if time.time() > t_end:
                raise MonitorError("timeout waiting for %r; got %r" % (tokens, self.buf[-300:]))
            data = self.port.read(max(1, getattr(self.port, "in_waiting", 0) or 1))
            if data:
                self.buf += data
                self._log(data)

    def sync(self, timeout=60):
        """Align the response stream: send an unknown command with a unique
        marker; the monitor answers "ERR unknown command '<marker>'" and a
        prompt, so everything before it (boot banner, stale prompts) is
        discarded and the next command starts on a clean stream."""
        marker = "sync%06d" % (int(time.time() * 1000) % 1000000)
        self.port.write(b"\r" + marker.encode() + b"\r")
        self.read_until([("unknown command '%s'" % marker).encode()], timeout)
        self.read_until([PROMPT], timeout)

    def cmd(self, line, timeout=30, prompt=PROMPT, allow_err=False):
        """Send one command line; return the response lines (echo removed).
        A monitor error line ("ERR ...") raises MonitorError unless allow_err."""
        self.port.write(line.encode() + b"\r")
        text, _ = self.read_until([prompt], timeout)
        lines = [ln.rstrip("\r") for ln in text.replace("\r\n", "\n").split("\n")]
        if lines and lines[0].strip() == line.strip():      # the echo
            lines = lines[1:]
        lines = [ln for ln in lines if ln.strip()]
        # monitor errors are "ERR <reason>" (not e.g. the "ERRLOG" dump line)
        errs = [ln for ln in lines if re.match(r"ERR\b", ln)]
        if errs and not allow_err:
            raise MonitorError("%s: %s" % (line, errs[0]))
        return lines

    # ---------------- base monitor (boot ROM and applications) ----------------
    def peek(self, addr, n=1, timeout=60):
        """Read n words. Every response line must carry the address it was
        asked for (addr + 4 * i): a value reported for another address is an
        error, not data."""
        if not isinstance(addr, int):
            raise MonitorError("peek: numeric address required, got %r" % (addr,))
        vals = []
        for ln in self.cmd("peek 0x%08x %d" % (addr, n), timeout=timeout):
            m = PEEK_RE.match(ln.strip())
            if not m:
                continue
            want = (addr + 4 * len(vals)) & 0xFFFFFFFF
            got = int(m.group(1), 16)
            if got != want:
                raise MonitorError("peek 0x%08x %d: word %d reported for 0x%08x, expected 0x%08x"
                                   % (addr, n, len(vals), got, want))
            vals.append(int(m.group(2), 16))
        if len(vals) != n:
            raise MonitorError("peek 0x%08x %d returned %d words" % (addr, n, len(vals)))
        return vals[0] if n == 1 else vals

    def poke(self, addr, value, timeout=30):
        r = self.cmd("poke 0x%08x 0x%08x" % (addr, value & 0xFFFFFFFF), timeout=timeout)
        if r != ["OK"]:
            raise MonitorError("poke 0x%08x: %r" % (addr, r))

    def regs(self, block):
        return self.cmd("regs %s" % block)

    def go(self, addr, timeout=120):
        """Jump to addr; returns the output up to the next prompt."""
        return self.cmd("go 0x%08x" % addr, timeout=timeout)

    def reboot(self, timeout=300, load=64):
        """Reset PD_CPU through the watchdog (doc/SOC_REGMAP.md "Watchdog
        reset"): stop it, set a short timeout, enable it with the reset
        request. The PMU resets the CPU, the boot ROM cold-boots (reset cause
        WATCHDOG), checks the image and starts it or its own monitor. Returns
        the boot output up to the first prompt (boot ROM banner included)."""
        self.poke(sm.DBG_BASE + sm.WDT["ctrl"], 0)
        self.poke(sm.DBG_BASE + sm.WDT["load"], load)
        self.port.write(b"poke 0x%08x 0x%08x\r" % (sm.DBG_BASE + sm.WDT["ctrl"], sm.WDT_CTRL_EN | sm.WDT_CTRL_RST_EN))
        self.read_until([ROM_BANNER], timeout)
        text, _ = self.read_until([PROMPT], timeout)
        lines = [ln.rstrip("\r") for ln in (ROM_BANNER.decode() + text).replace("\r\n", "\n").split("\n")]
        return [ln for ln in lines if ln.strip()]

    # ---------------- application commands ----------------
    def run_test(self, test_id, timeout=600):
        out = self.cmd("run %s" % test_id, timeout=timeout, allow_err=True)
        res = [(int(m.group(1)), m.group(2), m.group(3)) for m in map(TEST_RE.match, out) if m]
        verdict = "PASS" if res and all(r == "PASS" for _i, _n, r in res) and \
            not any(re.match(r"ERR\b", ln) for ln in out) else "FAIL"
        return verdict, res, out

    def info(self):
        return self.cmd("info")

    def sleep(self, state, ticks=None, timeout=300):
        """state: idle|sleep|deep; ticks=None -> wake by UART input. Returns the
        wake report; the monitor's own "ERR transition ..." line (a transition
        that did not complete) is returned as 'error', not raised, so the
        caller decides with every counter at hand."""
        if ticks is None:
            self.port.write(("sleep %s uart" % state).encode() + b"\r")
            self.read_until([WAKE_PROMPT], timeout)
            time.sleep(0.2)
            self.port.write(b"\r")
            text, _ = self.read_until([PROMPT], timeout)
        else:
            text = "\n".join(self.cmd("sleep %s %d" % (state, ticks), timeout=timeout, allow_err=True))
        m = WOKE_RE.search(text)
        if not m:
            raise MonitorError("sleep %s: no wake report in %r" % (state, text[-200:]))
        err = re.search(r"^ERR .*$", text, re.M)
        return {"result": int(m.group(1)), "rst_cause": int(m.group(2)), "wake_cause": int(m.group(3)),
                "sleep_cnt_delta": int(m.group(4)), "error": err.group(0) if err else None}

    def opp(self, op, timeout=120):
        out = self.cmd("opp %d" % op, timeout=timeout)
        m = [ln for ln in out if ln.startswith("opp ")]
        if not m or int(m[0].split()[1]) != op:
            raise MonitorError("opp %d: %r" % (op, out))
        return op

    def exit(self, code=0):
        self.port.write(("exit %d" % code).encode() + b"\r")

    # ---------------- debug application ----------------
    def dbg_dump(self, timeout=120):
        return self.cmd("dbg", timeout=timeout)

    def dbgrun(self, test, seed, iters=0, flags=0, timeout=900):
        """Returns (verdict, output lines). An expected crash prints a dump and
        returns to a monitor prompt; the verdict line decides."""
        out = self.cmd("dbgrun %d %d %d %d" % (test, seed, iters, flags), timeout=timeout, allow_err=True)
        verdict = "PASS" if any("DBGRUN RESULT: PASS" in ln for ln in out) else "FAIL"
        return verdict, out
