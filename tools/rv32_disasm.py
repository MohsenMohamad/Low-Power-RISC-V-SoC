#!/usr/bin/env python3
"""Minimal RV32IM + Zicsr disassembler (one 32-bit word at a time).

Used by dbg_decode.py to annotate trace entries without an external
toolchain. Unknown encodings are printed as '.word 0x...'.
"""

ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
       "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]
CSR = {0x300: "mstatus", 0x301: "misa", 0x304: "mie", 0x305: "mtvec", 0x340: "mscratch", 0x341: "mepc",
       0x342: "mcause", 0x343: "mtval", 0x344: "mip", 0xB00: "mcycle", 0xB02: "minstret",
       0xB80: "mcycleh", 0xB82: "minstreth", 0xC00: "cycle", 0xC01: "time", 0xC02: "instret",
       0xC80: "cycleh", 0xC82: "instreth", 0xF14: "mhartid"}


def _sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def disasm(w, pc=0):
    """Disassemble instruction word w at address pc; returns a string."""
    w &= 0xFFFFFFFF
    if w & 3 != 3:
        return ".half 0x%04x (compressed)" % (w & 0xFFFF)
    op, rd, f3 = w & 0x7F, (w >> 7) & 31, (w >> 12) & 7
    rs1, rs2, f7 = (w >> 15) & 31, (w >> 20) & 31, w >> 25
    r = lambda i: ABI[i]
    imm_i = _sx(w >> 20, 12)
    imm_s = _sx(((w >> 25) << 5) | ((w >> 7) & 31), 12)
    imm_b = _sx((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 0x3F) << 5)
                | (((w >> 8) & 0xF) << 1), 13)
    imm_u = w & 0xFFFFF000
    imm_j = _sx((((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) | (((w >> 20) & 1) << 11)
                | (((w >> 21) & 0x3FF) << 1), 21)
    if op == 0x37:
        return "lui %s, 0x%x" % (r(rd), imm_u >> 12)
    if op == 0x17:
        return "auipc %s, 0x%x" % (r(rd), imm_u >> 12)
    if op == 0x6F:
        t = (pc + imm_j) & 0xFFFFFFFF
        return "j 0x%08x" % t if rd == 0 else "jal %s, 0x%08x" % (r(rd), t)
    if op == 0x67 and f3 == 0:
        if rd == 0 and rs1 == 1 and imm_i == 0:
            return "ret"
        return "jalr %s, %d(%s)" % (r(rd), imm_i, r(rs1))
    if op == 0x63:
        names = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
        if f3 in names:
            if rs2 == 0 and f3 in (0, 1):
                return "%sz %s, 0x%08x" % (names[f3], r(rs1), (pc + imm_b) & 0xFFFFFFFF)
            return "%s %s, %s, 0x%08x" % (names[f3], r(rs1), r(rs2), (pc + imm_b) & 0xFFFFFFFF)
    if op == 0x03:
        names = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
        if f3 in names:
            return "%s %s, %d(%s)" % (names[f3], r(rd), imm_i, r(rs1))
    if op == 0x23:
        names = {0: "sb", 1: "sh", 2: "sw"}
        if f3 in names:
            return "%s %s, %d(%s)" % (names[f3], r(rs2), imm_s, r(rs1))
    if op == 0x13:
        if f3 == 0:
            if rd == 0 and rs1 == 0 and imm_i == 0:
                return "nop"
            if rs1 == 0:
                return "li %s, %d" % (r(rd), imm_i)
            if imm_i == 0:
                return "mv %s, %s" % (r(rd), r(rs1))
            return "addi %s, %s, %d" % (r(rd), r(rs1), imm_i)
        names = {2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
        if f3 in names:
            return "%s %s, %s, %d" % (names[f3], r(rd), r(rs1), imm_i)
        if f3 == 1 and f7 == 0:
            return "slli %s, %s, %d" % (r(rd), r(rs1), rs2)
        if f3 == 5 and f7 in (0, 0x20):
            return "%s %s, %s, %d" % ("srli" if f7 == 0 else "srai", r(rd), r(rs1), rs2)
    if op == 0x33:
        if f7 == 1:
            names = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
            return "%s %s, %s, %s" % (names[f3], r(rd), r(rs1), r(rs2))
        names = {(0, 0): "add", (0, 0x20): "sub", (1, 0): "sll", (2, 0): "slt", (3, 0): "sltu",
                 (4, 0): "xor", (5, 0): "srl", (5, 0x20): "sra", (6, 0): "or", (7, 0): "and"}
        if (f3, f7) in names:
            return "%s %s, %s, %s" % (names[(f3, f7)], r(rd), r(rs1), r(rs2))
    if op == 0x0F:
        return "fence.i" if f3 == 1 else "fence"
    if op == 0x73:
        if w == 0x00000073:
            return "ecall"
        if w == 0x00100073:
            return "ebreak"
        if w == 0x30200073:
            return "mret"
        if w == 0x10500073:
            return "wfi"
        if f3:
            csr = w >> 20
            cn = CSR.get(csr, "0x%03x" % csr)
            names = {1: "csrrw", 2: "csrrs", 3: "csrrc", 5: "csrrwi", 6: "csrrsi", 7: "csrrci"}
            if f3 in names:
                src = str(rs1) if f3 >= 5 else r(rs1)
                return "%s %s, %s, %s" % (names[f3], r(rd), cn, src)
    if op == 0x0B:
        return "picorv32.custom0 0x%08x" % w     # PicoRV32 IRQ instructions
    return ".word 0x%08x" % w


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        print("%08x  %s" % (int(a, 16), disasm(int(a, 16))))
