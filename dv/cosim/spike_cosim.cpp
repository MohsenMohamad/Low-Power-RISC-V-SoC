#include "spike_cosim.h"

#include <riscv/cfg.h>
#include <riscv/disasm.h>
#include <riscv/encoding.h>
#include <riscv/mmu.h>
#include <riscv/processor.h>
#include <riscv/simif.h>

#include <cstdio>
#include <iomanip>
#include <iostream>

namespace {
std::string hex(uint64_t v) {
  std::ostringstream o;
  o << "0x" << std::hex << std::setw(8) << std::setfill('0') << v;
  return o.str();
}
}  // namespace

// ---------------------------------------------------------------------------
// simif_t implementation: RAM regions backed by host memory, MMIO regions that
// read as zero and ignore writes (mirrors the testbench device behaviour).
// ---------------------------------------------------------------------------
class SpikeCosim::Sim : public simif_t {
 public:
  struct Ram { uint32_t base, size; std::vector<char> data; };
  std::vector<Ram> rams;
  std::vector<Region> mmio;
  cfg_t cfg;
  std::map<size_t, processor_t*> harts;
  std::unique_ptr<processor_t> proc;
  FILE* log = nullptr;

  char* addr_to_mem(reg_t paddr) override {
    for (auto& r : rams)
      if (paddr >= r.base && paddr < uint64_t(r.base) + r.size) return &r.data[paddr - r.base];
    return nullptr;
  }
  bool in_mmio(reg_t a, size_t len) const {
    for (auto& m : mmio)
      if (a >= m.base && a + len <= uint64_t(m.base) + m.size) return true;
    return false;
  }
  bool mmio_load(reg_t paddr, size_t len, uint8_t* bytes) override {
    if (!in_mmio(paddr, len)) return false;
    memset(bytes, 0, len);
    return true;
  }
  bool mmio_store(reg_t paddr, size_t len, const uint8_t*) override { return in_mmio(paddr, len); }
  void proc_reset(unsigned) override {}
  const cfg_t& get_cfg() const override { return cfg; }
  const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
  const char* get_symbol(uint64_t) override { return nullptr; }
};

SpikeCosim::SpikeCosim(const std::string& isa, uint32_t start_pc, std::vector<Region> ram,
                       std::vector<Region> mmio, const char* log_path)
    : sim_(new Sim) {
  static std::string isa_s, priv_s = "M";
  isa_s = isa;
  for (auto& r : ram) sim_->rams.push_back({r.base, r.size, std::vector<char>(r.size, 0)});
  sim_->mmio = mmio;
  sim_->cfg.isa = isa_s.c_str();
  sim_->cfg.priv = priv_s.c_str();
  sim_->cfg.pmpregions = 0;
  sim_->cfg.hartids = {0};
  sim_->log = fopen(log_path ? log_path : "/dev/null", "w");
  sim_->proc.reset(new processor_t(isa_s.c_str(), priv_s.c_str(), &sim_->cfg, sim_.get(), 0,
                                   false, sim_->log, std::cerr));
  sim_->harts[0] = sim_->proc.get();
  sim_->proc->enable_log_commits();
  sim_->proc->get_state()->pc = start_pc;
}

SpikeCosim::~SpikeCosim() {
  sim_->proc.reset();
  if (sim_->log) fclose(sim_->log);
}

void SpikeCosim::write_mem(uint32_t addr, uint8_t v) {
  char* p = sim_->addr_to_mem(addr);
  if (p) *p = char(v);
}

bool SpikeCosim::read_mem(uint32_t addr, uint8_t& v) const {
  char* p = sim_->addr_to_mem(addr);
  if (!p) return false;
  v = uint8_t(*p);
  return true;
}

uint32_t SpikeCosim::pc() const { return uint32_t(sim_->proc->get_state()->pc); }

// CSRs whose values are implementation specific (timing, IDs): the RTL value
// is copied into Spike instead of being compared.
static bool csr_is_impl_specific(uint32_t csr) {
  switch (csr) {
    case CSR_MCYCLE: case CSR_MCYCLEH: case CSR_CYCLE: case CSR_CYCLEH:
    case CSR_TIME: case CSR_TIMEH: case CSR_MARCHID: case CSR_MIMPID:
      return true;
    default:
      return false;
  }
}

bool SpikeCosim::step(const TraceEvent& e, std::string& err) {
  processor_t* p = sim_->proc.get();
  state_t* s = p->get_state();
  std::ostringstream o;
  steps_++;

  // Interrupt pending bits exactly as the RTL saw them for this event.
  reg_t mip = 0;
  if (e.mip & 1) mip |= MIP_MSIP;
  if (e.mip & 2) mip |= MIP_MTIP;
  if (e.mip & 4) mip |= MIP_MEIP;
  s->mip->backdoor_write_with_mask(MIP_MSIP | MIP_MTIP | MIP_MEIP, mip);

  uint32_t spc = uint32_t(s->pc);
  if (spc != e.pc) {
    o << "PC mismatch before step: rtl=" << hex(e.pc) << " spike=" << hex(spc)
      << (p->is_waiting_for_interrupt() ? " (spike in WFI)" : "");
    err = o.str();
    return false;
  }

  s->log_reg_write.clear();
  s->log_mem_read.clear();
  s->log_mem_write.clear();
  uint32_t mcause_before = uint32_t(p->get_csr(CSR_MCAUSE));
  uint32_t mepc_before = uint32_t(p->get_csr(CSR_MEPC));
  p->step(1);
  uint32_t npc = uint32_t(s->pc);
  uint32_t mcause = uint32_t(p->get_csr(CSR_MCAUSE));
  uint32_t mepc = uint32_t(p->get_csr(CSR_MEPC));
  uint32_t mtval = uint32_t(p->get_csr(CSR_MTVAL));

  std::string dis = p->get_disassembler()->disassemble(insn_t(e.insn));
  auto fail = [&](const std::string& what) {
    o << what << "\n    rtl : pc=" << hex(e.pc) << " insn=" << hex(e.insn) << " (" << dis << ")"
      << (e.irq ? " IRQ" : e.trap ? " TRAP" : "") << " next=" << hex(e.next_pc)
      << " cause=" << e.cause << " tval=" << hex(e.tval)
      << " rd_we=" << e.rd_we << " x" << e.rd << "=" << hex(e.rd_wdata)
      << " mip=" << e.mip
      << "\n    spike: next=" << hex(npc) << " mcause=" << hex(mcause) << " mepc=" << hex(mepc)
      << " mtval=" << hex(mtval) << " rs1(x" << ((e.insn >> 15) & 31) << ")="
      << hex(uint32_t(s->XPR[(e.insn >> 15) & 31])) << " rs2(x" << ((e.insn >> 20) & 31) << ")="
      << hex(uint32_t(s->XPR[(e.insn >> 20) & 31]));
    for (auto& w : s->log_reg_write)
      o << " w[" << (w.first >> 4) << (((w.first & 0xf) == 4) ? "csr" : "x") << "]="
        << hex(uint32_t(w.second.v[0]));
    err = o.str();
    return false;
  };

  if (npc != e.next_pc) return fail("next PC mismatch");

  if (e.irq || e.trap) {
    uint32_t exp = (e.irq ? 0x80000000u : 0u) | e.cause;
    if (mcause != exp) return fail("trap cause mismatch");
    if (mepc != e.pc) return fail("mepc mismatch");
    if (e.trap && mtval != e.tval) return fail("mtval mismatch");
    return true;
  }

  // Retired instruction: Spike must not have trapped.
  bool csr_insn = (e.insn & 0x7f) == 0x73 && ((e.insn >> 12) & 7) != 0;
  uint32_t csr = e.insn >> 20;
  if (!csr_insn && (mcause != mcause_before || mepc != mepc_before))
    return fail("spike trapped, rtl retired");

  // Register write
  bool sw = false;
  uint32_t srd = 0, sval = 0;
  for (auto& w : s->log_reg_write) {
    if ((w.first & 0xf) == 0 && (w.first >> 4) != 0) {
      sw = true;
      srd = uint32_t(w.first >> 4);
      sval = uint32_t(w.second.v[0]);
    }
  }
  if (csr_insn && csr_is_impl_specific(csr)) {
    // Spike holds RV32 values sign-extended to 64 bits.
    if (e.rd_we) s->XPR.write(e.rd, reg_t(int64_t(int32_t(e.rd_wdata))));
  } else {
    if (sw != e.rd_we) return fail("rd write presence mismatch");
    if (sw && (srd != e.rd || sval != e.rd_wdata)) return fail("rd write mismatch");
  }

  // Store
  if (e.mem_we != !s->log_mem_write.empty()) return fail("store presence mismatch");
  if (e.mem_we) {
    auto& w = s->log_mem_write.front();
    uint32_t a = uint32_t(std::get<0>(w));
    uint64_t v = std::get<1>(w);
    unsigned sz = std::get<2>(w);
    unsigned rsz = __builtin_popcount(e.mem_be);
    uint32_t rv = (e.mem_wdata >> (8 * (e.mem_addr & 3))) &
                  (rsz == 4 ? 0xffffffffu : ((1u << (8 * rsz)) - 1));
    if (a != e.mem_addr || sz != rsz || uint32_t(v) != rv) {
      o << "[store spike addr=" << hex(a) << " size=" << sz << " val=" << hex(v)
        << " | rtl addr=" << hex(e.mem_addr) << " size=" << rsz << " val=" << hex(rv) << "] ";
      return fail("store mismatch");
    }
  }
  return true;
}
