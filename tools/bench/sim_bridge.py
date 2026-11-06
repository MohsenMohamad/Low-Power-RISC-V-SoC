"""Simulation bridge: start the SoC simulation (sim/tb_soc.sv, Verilator,
built with the UART pseudo-terminal bridge: make bench-sim) with its UART on a
host pseudo-terminal (verif/debug/integ/dbg_uart_pty_bridge.sv + uart_pty.c),
so the bench opens the simulated SoC exactly like a serial port.

The simulation starts from the boot ROM with no application image in RAM:
the boot ROM finds no valid image and starts its UART monitor, and the bench
loads the firmware through it (tools/bench/loader.py), as on a board.
"""
import os
import select
import subprocess
import termios
import time
import tty

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIM_BIN = os.path.join(ROOT, "build", "sim", "vl_bench", "Vtb_soc")
ROM_HEX = os.path.join(ROOT, "build", "fw", "lpsoc", "rom.hex")


class PtyPort:
    """Minimal serial-port object on a pty (read / write / in_waiting / close),
    the subset of pyserial the bench uses."""

    def __init__(self, path, timeout=0.05):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        self.timeout = timeout

    @property
    def in_waiting(self):
        r, _, _ = select.select([self.fd], [], [], 0)
        return 4096 if r else 0

    def read(self, n=1):
        r, _, _ = select.select([self.fd], [], [], self.timeout)
        if not r:
            return b""
        try:
            return os.read(self.fd, n)
        except BlockingIOError:
            return b""

    def write(self, data):
        view = memoryview(data)
        while view:
            try:
                k = os.write(self.fd, view)
                view = view[k:]
            except BlockingIOError:
                select.select([], [self.fd], [], 0.1)

    def close(self):
        os.close(self.fd)


class SimTarget:
    def __init__(self, workdir, extra=(), timeout_ns=60_000_000_000):
        workdir = os.path.abspath(workdir)
        os.makedirs(workdir, exist_ok=True)
        self.workdir = workdir
        self.pty_file = os.path.join(workdir, "pty.txt")
        self.log = os.path.join(workdir, "sim.log")
        if os.path.exists(self.pty_file):
            os.remove(self.pty_file)
        for f in (SIM_BIN, ROM_HEX):
            if not os.path.exists(f):
                raise RuntimeError("%s missing: run 'make bench-sim fw' first" % f)
        # +timeout is in ns in sim/tb_soc.sv (audit W33): 60 s of simulated time
        args = [SIM_BIN, "+rom=" + ROM_HEX, "+pty", "+pty_file=" + self.pty_file,
                "+timeout=%d" % timeout_ns, "+uart_log=" + os.path.join(workdir, "uart.log"),
                "+cov=" + os.path.join(workdir, "cov.txt")] + list(extra)
        self.proc = subprocess.Popen(args, stdout=open(self.log, "w"), stderr=subprocess.STDOUT, cwd=ROOT)
        t_end = time.time() + 60
        while not os.path.exists(self.pty_file) or not open(self.pty_file).read().strip():
            if self.proc.poll() is not None or time.time() > t_end:
                raise RuntimeError("simulation did not open a pty (see %s)" % self.log)
            time.sleep(0.05)
        self.port = open(self.pty_file).read().strip()

    def last_words(self):
        """The testbench's own end-of-run line (timeout / verdict), if any."""
        try:
            lines = [l for l in open(self.log, errors="replace") if l.startswith("[tb]")]
        except OSError:
            return "no simulation log"
        return "; ".join(l.strip() for l in lines[-2:]) if lines else "no [tb] line"

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        return self.proc.returncode
