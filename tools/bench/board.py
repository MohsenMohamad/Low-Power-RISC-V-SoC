"""Board adapter: everything board-specific lives in this file.

A board profile gives the serial port, its settings and the commands to
reset / program the board. The bench (sequencer, loader, monitor adapter)
only uses BoardProfile.open_port(), reset(), program() and the address
constants, so the same scripts run against the simulation now and an FPGA
board or silicon later.

To add a board: copy FPGA_TEMPLATE, fill in the fields, select it with
'--board <name>'. Nothing here is specific to a particular FPGA vendor;
there are no constraints or bitstream build scripts in this repository.
"""
import subprocess
import time

try:
    import serial                     # pyserial
except ImportError:                   # pragma: no cover
    serial = None


class BoardProfile:
    def __init__(self, name, port=None, baud=115200, bytesize=8, parity="N", stopbits=1,
                 reset_cmd=None, program_cmd=None, power_cycle_cmd=None, dbg_base=0x4002_0000,
                 boot_timeout=60, cmd_timeout=60, notes=""):
        self.name = name
        self.port = port                      # e.g. /dev/ttyUSB1, or set by the sim bridge
        self.baud = baud
        self.bytesize, self.parity, self.stopbits = bytesize, parity, stopbits
        self.reset_cmd = reset_cmd            # host command that resets the board (list)
        self.program_cmd = program_cmd        # host command that loads the bitstream (list)
        self.power_cycle_cmd = power_cycle_cmd
        self.dbg_base = dbg_base
        self.boot_timeout = boot_timeout
        self.cmd_timeout = cmd_timeout        # scale up for slow targets (simulation)
        self.notes = notes

    def open_port(self, timeout=0.05):
        if serial is None:
            raise RuntimeError("pyserial is not installed (pip install pyserial)")
        if not self.port:
            raise RuntimeError("board %s: no serial port configured" % self.name)
        return serial.Serial(self.port, self.baud, bytesize=self.bytesize, parity=self.parity,
                             stopbits=self.stopbits, timeout=timeout)

    def _run(self, cmd, what):
        if not cmd:
            return False
        subprocess.run(cmd, check=True)
        time.sleep(0.5)
        return True

    def program(self):
        """Load the FPGA bitstream (no-op when not configured)."""
        return self._run(self.program_cmd, "program")

    def reset(self):
        """Hardware reset of the board (no-op when not configured)."""
        return self._run(self.reset_cmd, "reset")


# Verilator simulation through the pseudo-terminal bridge (sim_bridge.py sets
# the port). The bit rate of a pty is irrelevant; the simulated UART runs at
# clk_aon / UART_DIV. Simulation is slow: generous timeouts.
SIM = BoardProfile("sim", baud=115200, dbg_base=0x4F00_4000, boot_timeout=600, cmd_timeout=600,
                   notes="PicoRV32 integration preview, verif/debug/integ")

# Template for an FPGA board. Fill in and rename. [TEMPLATE]
FPGA_TEMPLATE = BoardProfile(
    "fpga-template",
    port="/dev/ttyUSB1",                        # USB-UART of the board
    baud=115200,                                # must match the SoC UART divisor
    reset_cmd=None,                             # e.g. ["openocd", "-f", "board.cfg", "-c", "init; reset; exit"]
    program_cmd=None,                           # e.g. ["openFPGALoader", "-b", "<board>", "soc.bit"]
    power_cycle_cmd=None,                       # e.g. a USB relay command
    dbg_base=0x4002_0000,
    boot_timeout=10, cmd_timeout=30,
    notes="template only: no board is targeted yet")

PROFILES = {p.name: p for p in (SIM, FPGA_TEMPLATE)}
