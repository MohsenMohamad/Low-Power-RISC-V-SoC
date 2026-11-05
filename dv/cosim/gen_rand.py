#!/usr/bin/env python3
"""Random RV32IM(+Zicsr/Zifencei) instruction-stream generator for Spike lockstep co-simulation.

Produces a self-contained assembly program:
  * random initial register file and a 16 KB random data region
  * a random body built from weighted snippets: ALU, M-extension (with corner
    operands), loads/stores (aligned, misaligned, cache-aliasing addresses that
    force evictions, uncached MMIO, unmapped -> access faults), forward branches,
    counted loops, JAL/JALR (incl. misaligned targets), CSR accesses (legal,
    read-only, non-existent), ecall/ebreak/illegal encodings, fence, fence.i,
    self-modifying code, WFI and software-raised interrupts
  * a trap handler (direct or vectored mtvec) that skips faulting instructions
    and acknowledges interrupts through the testbench IRQ_CLR register
The program ends by cleaning the D-cache (fence.i) and writing 1 to tohost.

Register conventions: x1-x25 random, x26 loop counter, x27 fault-return link,
x28 data base, x29 far/alias pointer, x30/x31 trap-handler scratch.
"""
import argparse
import random

RAND_REGS = list(range(1, 26))
MMIO = 0x40000000
UNMAPPED = 0x30000000
DATA_SIZE = 16384

# CSRs: (address, writable-in-random-stream)
CSR_RW = [0x300, 0x304, 0x340, 0x341, 0x342, 0x343, 0x320, 0xB00, 0xB80, 0xB02, 0xB82,
          0xB03, 0xB83, 0x323, 0x344, 0x310]
CSR_RO = [0x305, 0x301, 0xF11, 0xF12, 0xF13, 0xF14, 0xF15, 0xC00, 0xC02, 0xC80, 0xC82, 0xC01,
          0xC81]
# Read but never written by the stream: mtvec (would break the handler) and misa
# (WARL; Spike allows clearing extensions, this core implements misa read-only).
CSR_READ_ONLY_BY_CONVENTION = [0x305, 0x301]
# Not implemented by the core (and illegal in Spike with this configuration):
# S-mode, counteren/envcfg (no U-mode), F, custom, PMP (0 regions), hpmcounter (no Zihpm), debug
CSR_NONEXIST = [0x105, 0x180, 0x306, 0x30A, 0x001, 0x800, 0x5C0, 0x3A0, 0x3B0, 0x3EF, 0xC03, 0x7B0]


def enc_b(f3, rs1, rs2, off):
    o = off & 0x1FFF
    return (((o >> 12) & 1) << 31 | ((o >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15 |
            f3 << 12 | ((o >> 1) & 0xF) << 8 | ((o >> 11) & 1) << 7 | 0x63)


def enc_j(rd, off):
    o = off & 0x1FFFFF
    return (((o >> 20) & 1) << 31 | ((o >> 1) & 0x3FF) << 21 | ((o >> 11) & 1) << 20 |
            ((o >> 12) & 0xFF) << 12 | rd << 7 | 0x6F)


def enc_i(op, f3, rd, rs1, imm):
    return (imm & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op


class Gen:
    def __init__(self, seed, length, vectored):
        self.r = random.Random(seed)
        self.length = length
        self.vectored = vectored
        self.lines = []
        self.label = 0
        self.recent = []
        self.count = 0

    # ---------------------------------------------------------------- helpers
    def emit(self, s, n=1):
        self.lines.append("  " + s)
        self.count += n

    def lbl(self):
        self.label += 1
        return f"L{self.label}"

    def rd(self):
        r = self.r.choice(RAND_REGS)
        self.recent = (self.recent + [r])[-4:]
        return r

    def rd2(self):
        """Two distinct destination registers (address + data temporaries)."""
        a = self.rd()
        b = self.rd()
        while b == a:
            b = self.rd()
        return a, b

    def rs(self):
        if self.recent and self.r.random() < 0.5:
            return self.r.choice(self.recent)
        return self.r.choice([0] + RAND_REGS + [28, 30, 31])

    def imm12(self):
        return self.r.choice([0, 1, -1, 2047, -2048, self.r.randint(-2048, 2047), self.r.randint(-16, 16)])

    def special(self):
        return self.r.choice([0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 2, 0xFFFFFFFE,
                              self.r.getrandbits(32), self.r.getrandbits(8)])

    # ---------------------------------------------------------------- snippets
    def s_alu_rr(self):
        op = self.r.choice(["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"])
        self.emit(f"{op} x{self.rd()}, x{self.rs()}, x{self.rs()}")

    def s_alu_ri(self):
        op = self.r.choice(["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"])
        imm = self.r.randint(0, 31) if op in ("slli", "srli", "srai") else self.imm12()
        self.emit(f"{op} x{self.rd()}, x{self.rs()}, {imm}")

    def s_upper(self):
        op = self.r.choice(["lui", "auipc"])
        self.emit(f"{op} x{self.rd()}, {self.r.randint(0, 0xFFFFF)}")

    def s_muldiv(self):
        op = self.r.choice(["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"])
        a, b = self.rs(), self.rs()
        if self.r.random() < 0.4:
            a, b = self.rd(), self.rd()
            self.emit(f"li x{a}, {self.special()}", 2)
            self.emit(f"li x{b}, {self.special()}", 2)
        self.emit(f"{op} x{self.rd()}, x{a}, x{b}")
        if self.r.random() < 0.3:   # back-to-back M ops / dependent use
            self.emit(f"{self.r.choice(['div', 'rem', 'mul'])} x{self.rd()}, x{self.recent[-1]}, x{b}")

    def mem_off(self, size):
        off = self.r.randint(-2048, 2047 - size)
        if self.r.random() < 0.92:
            off &= ~(size - 1)
        return off

    def s_load(self):
        op, size = self.r.choice([("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)])
        self.emit(f"{op} x{self.rd()}, {self.mem_off(size)}(x28)")

    def s_store(self):
        op, size = self.r.choice([("sb", 1), ("sh", 2), ("sw", 4)])
        self.emit(f"{op} x{self.rs()}, {self.mem_off(size)}(x28)")

    def s_far(self):
        # Same cache set, different tag: addresses 2 KB apart alias in a 2 KB way.
        k = self.r.randint(0, DATA_SIZE // 2048 - 1)
        line = self.r.randint(0, 127) if self.r.random() < 0.3 else self.r.randint(0, 3)
        off = k * 2048 + line * 16 + self.r.choice([0, 4, 8, 12])
        self.emit(f"la x29, data + {off}", 2)
        for _ in range(self.r.randint(1, 3)):
            if self.r.random() < 0.5:
                self.emit(f"sw x{self.rs()}, {self.r.choice([0, 4, 8, 12])}(x29)")
            else:
                op = self.r.choice(["lw", "lh", "lbu"])
                self.emit(f"{op} x{self.rd()}, {self.r.choice([0, 4, 8, 12])}(x29)")

    def s_dep_chain(self):
        a = self.rd()
        self.emit(f"lw x{a}, {self.mem_off(4)}(x28)")
        b = self.rd()
        self.emit(f"{self.r.choice(['add', 'xor', 'sub'])} x{b}, x{a}, x{a}")
        if self.r.random() < 0.5:
            self.emit(f"sw x{b}, {self.mem_off(4)}(x28)")
        else:
            l = self.lbl()
            self.emit(f"beq x{b}, x{a}, {l}")
            self.emit(f"addi x{self.rd()}, x{b}, 1")
            self.lines.append(f"{l}:")

    def s_uncached(self):
        off = self.r.choice([0x10, 0x14, 0x18, 0x100, 0xFFC])
        self.emit(f"li x29, {MMIO + off}", 2)
        if self.r.random() < 0.5:
            self.emit(f"lw x{self.rd()}, 0(x29)")
        else:
            self.emit(f"{self.r.choice(['sw', 'sh', 'sb'])} x{self.rs()}, 0(x29)")

    def s_access_fault(self):
        kind = self.r.choice(["load", "store", "fetch"])
        self.emit(f"li x29, {UNMAPPED + 4 * self.r.randint(0, 255)}", 2)
        if kind == "load":
            self.emit(f"lw x{self.rd()}, 0(x29)")
        elif kind == "store":
            self.emit(f"sw x{self.rs()}, 0(x29)")
        else:
            l = self.lbl()
            self.emit(f"la x27, {l}", 2)
            self.emit("jalr x0, 0(x29)")
            self.lines.append(f"{l}:")

    def body_simple(self, n):
        for _ in range(n):
            self.r.choice([self.s_alu_rr, self.s_alu_ri, self.s_upper, self.s_load, self.s_store])()

    def s_branch(self):
        op = self.r.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
        l = self.lbl()
        self.emit(f"{op} x{self.rs()}, x{self.rs()}, {l}")
        self.body_simple(self.r.randint(0, 4))
        self.lines.append(f"{l}:")

    def s_loop(self):
        l = self.lbl()
        self.emit(f"li x26, {self.r.randint(1, 6)}")
        self.lines.append(f"{l}:")
        self.body_simple(self.r.randint(1, 5))
        self.emit("addi x26, x26, -1")
        self.emit(f"bnez x26, {l}")

    def s_jump(self):
        l = self.lbl()
        if self.r.random() < 0.5:
            self.emit(f"jal x{self.rd()}, {l}")
        else:
            t = self.rd()
            self.emit(f"la x{t}, {l}", 2)
            self.emit(f"jalr x{self.rd()}, {self.r.choice([0, 0, 1])}(x{t})")  # bit0 is ignored
        self.body_simple(self.r.randint(0, 3))
        self.lines.append(f"{l}:")

    def s_misaligned_jump(self):
        kind = self.r.choice(["jalr", "jal", "branch"])
        if kind == "jalr":
            t = self.rd()
            l = self.lbl()
            self.emit(f"la x{t}, {l}", 2)
            self.emit(f"jalr x{self.rd()}, 2(x{t})")
            self.emit("nop")
            self.lines.append(f"{l}:")
            self.emit("nop")
        elif kind == "jal":
            self.emit(f".word 0x{enc_j(self.r.choice(RAND_REGS), 6):08x}  # jal +6 (misaligned)")
            self.emit("nop")
            self.emit("nop")
        else:
            f3 = self.r.choice([0, 1, 4, 5, 6, 7])
            self.emit(f".word 0x{enc_b(f3, self.rs(), self.rs(), 10):08x}  # branch +10 (misaligned if taken)")
            self.emit("nop")
            self.emit("nop")
            self.emit("nop")

    def s_csr(self):
        r = self.r.random()
        if r < 0.55:
            csr = self.r.choice(CSR_RW)
            op = self.r.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"])
            if csr in (0x300,) and self.r.random() < 0.7:
                # mstatus: mostly flip MIE/MPIE
                t = self.rd()
                self.emit(f"li x{t}, {self.r.choice([0x8, 0x80, 0x88, 0x0, 0xFFFFFFFF])}", 2)
                self.emit(f"{self.r.choice(['csrrs', 'csrrc', 'csrrw'])} x{self.rd()}, 0x{csr:03x}, x{t}")
                return
            if op.endswith("i"):
                self.emit(f"{op} x{self.rd()}, 0x{csr:03x}, {self.r.randint(0, 31)}")
            else:
                self.emit(f"{op} x{self.rd()}, 0x{csr:03x}, x{self.rs()}")
        elif r < 0.85:
            csr = self.r.choice(CSR_RO)
            if csr in CSR_READ_ONLY_BY_CONVENTION or self.r.random() < 0.8:
                self.emit(f"csrr x{self.rd()}, 0x{csr:03x}")
            else:   # write to read-only CSR -> illegal instruction
                self.emit(f"csrrw x{self.rd()}, 0x{csr:03x}, x{self.rs()}")
        else:
            csr = self.r.choice(CSR_NONEXIST)
            self.emit(f"csrrs x{self.rd()}, 0x{csr:03x}, x0")

    def s_system(self):
        k = self.r.choice(["ecall", "ebreak", "illegal", "illegal", "fence", "fence.i"])
        if k == "illegal":
            rd, rs1, rs2 = self.r.randint(0, 31), self.r.randint(0, 31), self.r.randint(0, 31)
            w = self.r.choice([
                0x00000000, 0xFFFFFFFF,
                (self.r.getrandbits(32) & ~0x7F) | 0x0B,                     # custom-0
                (self.r.getrandbits(32) & ~0x7F) | 0x5B,                     # custom-2
                0x0000_0001 | self.r.getrandbits(15) << 2,                   # compressed
                (0x7F << 25) | rs2 << 20 | rs1 << 15 | rd << 7 | 0x33,       # bad funct7
                (0x20 << 25) | rs2 << 20 | rs1 << 15 | 1 << 12 | rd << 7 | 0x33,
                (0x20 << 25) | self.r.randint(0, 31) << 20 | rs1 << 15 | 1 << 12 | rd << 7 | 0x13,  # slli bad
                enc_i(0x03, 3, rd, rs1, 0),                                  # ld (RV64)
                enc_i(0x03, 6, rd, rs1, 0),                                  # lwu
                enc_i(0x23, 3, 0, rs1, 0) | rs2 << 20,                        # sd
                enc_i(0x67, 1, rd, rs1, 0),                                  # jalr f3!=0
                enc_b(2, rs1, rs2, 8),                                       # branch f3=2
                enc_i(0x73, 4, rd, rs1, 0x300),                              # csr f3=4
                0x10200073,                                                  # sret (no S)
                0x7B200073,                                                  # dret
                enc_i(0x0F, 2, rd, rs1, 0),                                  # misc-mem f3=2
            ])
            self.emit(f".word 0x{w:08x}  # illegal")
        else:
            self.emit(k)

    def s_wfi(self):
        t = self.rd()
        self.emit(f"li x{t}, 0x888")
        self.emit(f"csrs mie, x{t}")
        if self.r.random() < 0.5:
            self.emit("csrsi mstatus, 8")
        self.emit("wfi")

    def s_swirq(self):
        t, v = self.rd2()
        self.emit(f"li x{t}, {MMIO + 8}", 2)
        self.emit(f"li x{v}, {self.r.choice([0x8, 0x80, 0x800, 0x888])}")
        self.emit(f"sw x{v}, 0(x{t})")
        if self.r.random() < 0.6:
            self.emit(f"li x{v}, 0x888")
            self.emit(f"csrs mie, x{v}")
            self.emit("csrsi mstatus, 8")
        self.body_simple(self.r.randint(0, 3))

    def s_smc(self):
        l = self.lbl()
        t, v = self.rd2()
        new = enc_i(0x13, 0, self.r.choice(RAND_REGS), 0, self.r.randint(-2048, 2047))
        self.emit(f"la x{t}, {l}", 2)
        self.emit(f"li x{v}, 0x{new:08x}", 2)
        self.emit(f"sw x{v}, 0(x{t})")
        self.emit("fence.i")
        self.lines.append(f"{l}:")
        self.emit("nop  # overwritten at run time")

    # ---------------------------------------------------------------- program
    def program(self):
        snippets = [
            (self.s_alu_rr, 14), (self.s_alu_ri, 14), (self.s_upper, 3), (self.s_muldiv, 8),
            (self.s_load, 10), (self.s_store, 10), (self.s_far, 6), (self.s_dep_chain, 5),
            (self.s_uncached, 2), (self.s_access_fault, 1.5), (self.s_branch, 6), (self.s_loop, 2),
            (self.s_jump, 3), (self.s_misaligned_jump, 1), (self.s_csr, 5), (self.s_system, 2.5),
            (self.s_wfi, 0.5), (self.s_swirq, 0.7), (self.s_smc, 0.7),
        ]
        funcs, weights = zip(*snippets)
        while self.count < self.length:
            self.r.choices(funcs, weights)[0]()

        out = ["# Generated by gen_rand.py", "  .section .text.init", "  .globl _start", "_start:"]
        out.append("  la x30, vtable + 1" if self.vectored else "  la x30, trap_handler")
        out.append("  csrw mtvec, x30")
        if self.r.random() < 0.5:
            out.append("  li x30, 0x888\n  csrw mie, x30\n  csrsi mstatus, 8")
        for reg in range(1, 26):
            out.append(f"  li x{reg}, 0x{self.special():08x}")
        out += ["  li x26, 0", "  li x27, 0", "  la x28, data + 8192", "  la x29, data", "  li x30, 0", "  li x31, 0"]
        out += self.lines
        out += [
            "  # end of test: mask interrupts (the handler owns x30/x31), clean the",
            "  # D-cache so memory can be compared, report pass",
            "  csrci mstatus, 8",
            "  fence.i",
            "  la x1, tohost",
            "  li x2, 1",
            "  sw x2, 0(x1)",
            "end_loop: j end_loop",
            "",
            "  .align 6",
            "vtable:",
        ]
        out += ["  j trap_handler"] * 16
        out += [
            "trap_handler:",
            "  csrr x30, mcause",
            "  bltz x30, 1f",
            "  li x31, 1",
            "  beq x30, x31, 2f",
            "  csrr x31, mepc",
            "  addi x31, x31, 4",
            "  csrw mepc, x31",
            "  mret",
            "2:",
            "  csrw mepc, x27",
            "  mret",
            "1:",
            "  andi x30, x30, 31",
            "  li x31, 1",
            "  sll x30, x31, x30",
            f"  li x31, {MMIO + 4}",
            "  sw x30, 0(x31)",
            "  mret",
            "",
            '  .section .tohost, "aw", @progbits',
            "  .align 6",
            "  .globl tohost",
            "tohost: .word 0",
            "  .align 6",
            "  .globl fromhost",
            "fromhost: .word 0",
            "",
            "  .data",
            "  .align 12",
            "data:",
        ]
        for i in range(0, DATA_SIZE // 4, 8):
            out.append("  .word " + ", ".join(f"0x{self.r.getrandbits(32):08x}" for _ in range(8)))
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--length", type=int, default=3000, help="approximate instruction count")
    ap.add_argument("--vectored", type=int, choices=[0, 1], default=None)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    vec = a.vectored if a.vectored is not None else a.seed % 2
    with open(a.out, "w") as f:
        f.write(Gen(a.seed, a.length, bool(vec)).program())


if __name__ == "__main__":
    main()
