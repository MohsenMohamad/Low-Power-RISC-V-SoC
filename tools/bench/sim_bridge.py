"""Simulation bridge: start the Verilator simulation with its UART on a
pseudo-terminal (verif/debug/integ/dbg_uart_pty_bridge.sv + uart_pty.c) and
hand the pty path to the board profile, so the bench opens the simulation
exactly like a serial port.
"""
import os
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIM_BIN = os.path.join(ROOT, "build", "verif_debug", "integ", "Vtb_dbg_soc")
ROM_HEX = os.path.join(ROOT, "build", "fw", "lpsoc-picorv32", "rom.hex")


class SimTarget:
    def __init__(self, workdir, ram_hex=None, extra=(), timeout_cycles=4_000_000_000):
        workdir = os.path.abspath(workdir)
        os.makedirs(workdir, exist_ok=True)
        self.workdir = workdir
        self.pty_file = os.path.join(workdir, "pty.txt")
        self.log = os.path.join(workdir, "sim.log")
        if os.path.exists(self.pty_file):
            os.remove(self.pty_file)
        for f in (SIM_BIN, ROM_HEX):
            if not os.path.exists(f):
                raise RuntimeError("%s missing: run 'make -C verif/debug integ integ-fw' first" % f)
        args = [SIM_BIN, "+rom_hex=" + ROM_HEX, "+monitor", "+pty", "+pty_file=" + self.pty_file,
                "+timeout=%d" % timeout_cycles, "+uart_log=" + os.path.join(workdir, "uart.log")]
        if ram_hex:
            args.append("+ram_hex=" + ram_hex)
        args += list(extra)
        self.proc = subprocess.Popen(args, stdout=open(self.log, "w"), stderr=subprocess.STDOUT, cwd=workdir)
        t_end = time.time() + 30
        while not os.path.exists(self.pty_file):
            if self.proc.poll() is not None or time.time() > t_end:
                raise RuntimeError("simulation did not open a pty (see %s)" % self.log)
            time.sleep(0.05)
        self.port = open(self.pty_file).read().strip()

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
