// ISA-level functional coverage sampled from the commit trace.
// Bins are named strings; counts are appended to a text file and merged /
// checked against the coverage plan by scripts/cov_report.py.
#pragma once
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>

#include "spike_cosim.h"

class IsaCoverage {
 public:
  static std::string mnemonic(uint32_t i) {
    uint32_t op = i & 0x7f, f3 = (i >> 12) & 7, f7 = i >> 25;
    static const char* ld[] = {"lb", "lh", "lw", "?", "lbu", "lhu", "?", "?"};
    static const char* st[] = {"sb", "sh", "sw", "?", "?", "?", "?", "?"};
    static const char* br[] = {"beq", "bne", "?", "?", "blt", "bge", "bltu", "bgeu"};
    static const char* opi[] = {"addi", "slli", "slti", "sltiu", "xori", "srli", "ori", "andi"};
    static const char* opr[] = {"add", "sll", "slt", "sltu", "xor", "srl", "or", "and"};
    static const char* mul[] = {"mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"};
    static const char* csr[] = {"?", "csrrw", "csrrs", "csrrc", "?", "csrrwi", "csrrsi", "csrrci"};
    switch (op) {
      case 0x37: return "lui";
      case 0x17: return "auipc";
      case 0x6f: return "jal";
      case 0x67: return "jalr";
      case 0x63: return br[f3];
      case 0x03: return ld[f3];
      case 0x23: return st[f3];
      case 0x13: return (f3 == 5 && (f7 & 0x20)) ? "srai" : opi[f3];
      case 0x33:
        if (f7 == 1) return mul[f3];
        if (f7 == 0x20) return f3 == 0 ? "sub" : "sra";
        return opr[f3];
      case 0x0f: return f3 == 1 ? "fence.i" : "fence";
      case 0x73:
        if (f3) return csr[f3];
        if (i == 0x00000073) return "ecall";
        if (i == 0x00100073) return "ebreak";
        if (i == 0x30200073) return "mret";
        if (i == 0x10500073) return "wfi";
        return "?";
      default: return "?";
    }
  }

  void sample(const TraceEvent& e) {
    if (e.irq) { hit("irq:" + std::to_string(e.cause)); return; }
    std::string m = mnemonic(e.insn);
    if (e.trap) {
      hit("trap:" + std::to_string(e.cause));
      if (e.cause == 2) hit("trap:2:" + std::string(m == "?" ? "unknown" : "known_op"));
      return;
    }
    hit("insn:" + m);
    uint32_t op = e.insn & 0x7f;
    if (op == 0x63) hit("br:" + m + (e.next_pc != e.pc + 4 ? ":taken" : ":nottaken"));
    if (op == 0x03 || op == 0x23) {
      static const char* sz[] = {"b", "h", "w", "?"};
      hit(std::string(op == 0x03 ? "ld:" : "st:") + sz[(e.insn >> 12) & 3] + ":off" +
          std::to_string(e.mem_addr & 3));
    }
    if (op == 0x73 && ((e.insn >> 12) & 7)) {
      char b[32];
      bool wr = ((e.insn >> 12) & 3) == 1 || ((e.insn >> 15) & 31) != 0;
      snprintf(b, sizeof b, "csr:%03x:%s", e.insn >> 20, wr ? "w" : "r");
      hit(b);
    }
    if (e.rd_we) {
      hit("rd:x" + std::to_string(e.rd));
      if (e.rd_wdata == 0) hit("val:zero");
      if (e.rd_wdata == 0xffffffffu) hit("val:minus1");
      if (e.rd_wdata == 0x80000000u) hit("val:intmin");
    }
    // Back-to-back dependent pairs as seen at commit (producer rd used as rs)
    uint32_t rs1 = (e.insn >> 15) & 31, rs2 = (e.insn >> 20) & 31;
    if (prev_rd_ && (rs1 == prev_rd_ || rs2 == prev_rd_))
      hit(std::string("dep:") + (prev_load_ ? "load" : "alu") + "->" + m);
    prev_rd_ = e.rd_we ? e.rd : 0;
    prev_load_ = op == 0x03;
  }

  void write(const std::string& path) const {
    FILE* f = fopen(path.c_str(), "a");
    if (!f) return;
    for (auto& [k, v] : bins_) fprintf(f, "%s %lu\n", k.c_str(), (unsigned long)v);
    fclose(f);
  }

 private:
  std::map<std::string, uint64_t> bins_;
  uint32_t prev_rd_ = 0;
  bool prev_load_ = false;
  void hit(const std::string& b) { bins_[b]++; }
};
