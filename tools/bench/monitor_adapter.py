"""Protocol adapter for the Session 3 UART bring-up monitor.

This is the only module that knows the monitor protocol (fw/app/monitor.c,
fw/app/main.c, doc/firmware.md on branch claude/zealous-planck-kdx8mw):

  prompt "mon> " after every command; "zzz> " before a UART-wake sleep
  input echoed character by character, line ends with \\r or \\n
  output lines end with \\r\\n; errors start with "ERR"
  peek <addr|blk.reg> [n]   -> "0x%08x: 0x%08x" per word (n <= 256)
  poke <addr|blk.reg> <v>   -> "OK"
  regs <block>              -> "blk.name 0xaddr: 0xvalue" lines
  go <addr>                 -> "jumping to 0x%08x", then the image runs
  reset                     -> "resetting CPU domain", boot ROM restarts
  run <id|all>              -> "[TEST n] name PASS|FAIL|SKIP" ..., "SUITE RESULT: PASS|FAIL"   (app)
  info / list               -> free text                                           (app)
  sleep <idle|sleep|deep> <ticks|uart> -> "woke: result r, rst_cause c, wake_src w, off_time t" (app)
  opp <0..2>                -> "opp n"                                             (app)
  exit [code]               -> ends a simulation                                   (app)
Debug application extension (fw/debug/app/dbg_app.c, same framework):
  dbg                       -> crash-format dump (reason "request")
  dbgrun <t> <seed> [iters] [flags] -> test output, "DBGRUN RESULT: PASS|FAIL"

There is no load or checksum command: images are written with poke and
verified by peek read-back plus a host-side CRC (tools/bench/loader.py);
the boot ROM additionally checks the image header CRC on 'reset'.
"""
import re
import time

PROMPT = b"mon> "
WAKE_PROMPT = b"zzz> "
PEEK_RE = re.compile(r"^0x([0-9a-fA-F]{8}): 0x([0-9a-fA-F]{8})$")
TEST_RE = re.compile(r"^\[TEST +(\d+)\] +(\S+) +(PASS|FAIL|SKIP)")
WOKE_RE = re.compile(r"woke: result (-?\d+), rst_cause (\d+), wake_src (\d+), off_time (\d+)")


class MonitorError(Exception):
    pass


class Monitor:
    """Command/response layer on a byte port (pyserial Serial or compatible).

    capture: optional callable(line_bytes, t) receiving every complete line
    received from the target with a timestamp (lab log)."""

    def __init__(self, port, capture=None, echo_timeout=5.0):
        self.port = port
        self.capture = capture
        self.buf = b""
        self.echo_timeout = echo_timeout

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

    def cmd(self, line, timeout=30, prompt=PROMPT):
        """Send one command line; return the response lines (echo removed)."""
        self.port.write(line.encode() + b"\r")
        text, _ = self.read_until([prompt], timeout)
        lines = [ln.rstrip("\r") for ln in text.replace("\r\n", "\n").split("\n")]
        # first line is the echo of the command
        if lines and lines[0].strip() == line.strip():
            lines = lines[1:]
        lines = [ln for ln in lines if ln.strip()]
        errs = [ln for ln in lines if ln.startswith("ERR")]
        if errs:
            raise MonitorError("%s: %s" % (line, errs[0]))
        return lines

    # ---------------- base monitor (boot ROM and application) ----------------
    def peek(self, addr, n=1, timeout=60):
        a = addr if isinstance(addr, str) else "0x%08x" % addr
        vals = []
        for ln in self.cmd("peek %s %d" % (a, n), timeout=timeout):
            m = PEEK_RE.match(ln.strip())
            if m:
                vals.append(int(m.group(2), 16))
        if len(vals) != n:
            raise MonitorError("peek %s %d returned %d words" % (a, n, len(vals)))
        return vals[0] if n == 1 else vals

    def poke(self, addr, value, timeout=30):
        a = addr if isinstance(addr, str) else "0x%08x" % addr
        r = self.cmd("poke %s 0x%08x" % (a, value & 0xFFFFFFFF), timeout=timeout)
        if "OK" not in r:
            raise MonitorError("poke %s: %r" % (a, r))

    def regs(self, block):
        return self.cmd("regs %s" % block)

    def go(self, addr, timeout=120):
        """Jump to addr; returns the output up to the next prompt."""
        return self.cmd("go 0x%08x" % addr, timeout=timeout)

    def reset(self, timeout=300):
        """PMU software reset of PD_CPU; returns the boot output up to the prompt."""
        return self.cmd("reset", timeout=timeout)

    # ---------------- application commands ----------------
    def run_test(self, test_id, timeout=600):
        out = self.cmd("run %s" % test_id, timeout=timeout)
        res = [(int(m.group(1)), m.group(2), m.group(3)) for m in map(TEST_RE.match, out) if m]
        verdict = "PASS" if any("SUITE RESULT: PASS" in ln for ln in out) else "FAIL"
        return verdict, res, out

    def info(self):
        return self.cmd("info")

    def sleep(self, state, ticks=None, timeout=300):
        """state: idle|sleep|deep; ticks=None -> wake by UART input."""
        if ticks is None:
            self.port.write(("sleep %s uart" % state).encode() + b"\r")
            self.read_until([WAKE_PROMPT], timeout)
            time.sleep(0.2)
            self.port.write(b"\r")
            text, _ = self.read_until([PROMPT], timeout)
        else:
            text = "\n".join(self.cmd("sleep %s %d" % (state, ticks), timeout=timeout))
        m = WOKE_RE.search(text)
        if not m:
            raise MonitorError("sleep %s: no wake report in %r" % (state, text[-200:]))
        return {"result": int(m.group(1)), "rst_cause": int(m.group(2)), "wake_src": int(m.group(3)),
                "off_time": int(m.group(4))}

    def opp(self, op, timeout=120):
        out = self.cmd("opp %d" % op, timeout=timeout)
        m = [ln for ln in out if ln.startswith("opp ")]
        if not m or int(m[0].split()[1]) != op:
            raise MonitorError("opp %d: %r" % (op, out))
        return op

    def exit(self, code=0):
        self.port.write(("exit %d" % code).encode() + b"\r")

    # ---------------- debug application extension ----------------
    def dbg_dump(self, timeout=120):
        return self.cmd("dbg", timeout=timeout)

    def dbgrun(self, test, seed, iters=0, flags=0, timeout=900):
        """Returns (verdict, output lines). A crash returns to the base
        monitor prompt after the dump; verdict is then FAIL."""
        out = self.cmd("dbgrun %d %d %d %d" % (test, seed, iters, flags), timeout=timeout)
        verdict = "PASS" if any("DBGRUN RESULT: PASS" in ln for ln in out) else "FAIL"
        return verdict, out
