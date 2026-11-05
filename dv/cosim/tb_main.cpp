// Verilator testbench for cpu_top: AXI4-Lite memory, interrupt stimulus,
// lockstep Spike co-simulation, signature dump and ISA coverage collection.
//
// Plusargs:
//   +elf=<file>          program (required)
//   +cosim=0|1           lockstep compare against Spike (default 1)
//   +max_cycles=<n>      timeout (default 5000000)
//   +seed=<n>            stimulus seed (back-pressure, latency, interrupts)
//   +ready_pct=<p>       AXI READY probability in % (default 100)
//   +max_lat=<n>         max extra AXI response latency (default 0)
//   +irq_rate=<n>        random interrupt assertions per 10000 cycles (default 0)
//   +memcmp=0|1          compare final RAM image with Spike (default 0)
//   +sig=<file>          dump begin_signature..end_signature (4-byte words)
//   +cov=<file>          append ISA functional-coverage counts
//   +trace=<file>        RTL commit trace
//   +spike_log=<file>    Spike commit log
//   +idle_pct=<p>        % of WFI sleeps in which the PMU idle handshake is
//                        exercised (idle_req/idle_ack, default 50)
#include <verilated.h>
#if VM_COVERAGE
#include <verilated_cov.h>
#endif
#include "Vcpu_top.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

#include "../common/axil_mem.h"
#include "../common/elf32.h"
#include "isa_cov.h"
#include "spike_cosim.h"

static constexpr uint32_t RAM_BASE = 0x80000000u;
static constexpr uint32_t RAM_SIZE = 4u << 20;
static constexpr uint32_t MMIO_BASE = 0x40000000u;

static std::string plus_str(const char* name, const std::string& def = "") {
  const char* v = Verilated::commandArgsPlusMatch(name);
  std::string pre = std::string("+") + name + "=";
  if (v && *v && std::string(v).rfind(pre, 0) == 0) return std::string(v + pre.size());
  return def;
}
static uint64_t plus_u64(const char* name, uint64_t def) {
  std::string s = plus_str(name);
  return s.empty() ? def : std::stoull(s, nullptr, 0);
}

int main(int argc, char** argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  auto top = std::make_unique<Vcpu_top>(ctx.get());

  std::string elf_path = plus_str("elf");
  if (elf_path.empty()) { std::cerr << "usage: +elf=<file>\n"; return 2; }
  bool cosim_en = plus_u64("cosim", 1);
  uint64_t max_cycles = plus_u64("max_cycles", 5000000);
  uint64_t seed = plus_u64("seed", 1);
  int irq_rate = int(plus_u64("irq_rate", 0));
  bool memcmp_en = plus_u64("memcmp", 0);
  std::string sig_path = plus_str("sig"), cov_path = plus_str("cov"), trace_path = plus_str("trace");
  std::string spike_log = plus_str("spike_log");

  Elf32Image elf = Elf32Image::load(elf_path);
  uint32_t tohost = elf.sym("tohost");

  AxilMem mem;
  mem.add_ram(RAM_BASE, RAM_SIZE);
  mem.mmio_base = MMIO_BASE;
  mem.ready_pct = int(plus_u64("ready_pct", 100));
  mem.max_latency = int(plus_u64("max_lat", 0));
  mem.rng.seed(uint32_t(seed));
  std::mt19937 irq_rng(uint32_t(seed * 7919 + 1));

  std::unique_ptr<SpikeCosim> spike;
  if (cosim_en)
    spike.reset(new SpikeCosim("rv32im_zicsr_zifencei_zicntr", elf.entry, {{RAM_BASE, RAM_SIZE}},
                               {{MMIO_BASE, 0x1000}}, spike_log.empty() ? nullptr : spike_log.c_str()));
  elf.write_to([&](uint32_t a, uint8_t v) {
    if (uint8_t* p = mem.ptr(a)) *p = v;
    if (spike) spike->write_mem(a, v);
  });

  // Interrupt sources: bit0 MSIP, bit1 MTIP, bit2 MEIP. Software clears them via
  // MMIO IRQ_CLR (+0x4) and can set them via IRQ_SET (+0x8), using mip bit
  // positions (3, 7, 11). +0xC is a console byte.
  uint32_t irq_src = 0;
  auto mip_to_src = [](uint32_t v) { return (v >> 3 & 1) | (v >> 7 & 1) << 1 | (v >> 11 & 1) << 2; };
  mem.on_mmio_write = [&](uint32_t off, uint32_t d, uint8_t) {
    if (off == 0x4) irq_src &= ~mip_to_src(d);
    else if (off == 0x8) irq_src |= mip_to_src(d);
    else if (off == 0xC) { std::putchar(int(d & 0xff)); std::fflush(stdout); }
  };

  FILE* trace = trace_path.empty() ? nullptr : fopen(trace_path.c_str(), "w");
  IsaCoverage cov;

  top->boot_addr_i = elf.entry;
  top->rst_n = 0;
  top->clk = 0;
  top->irq_software_i = top->irq_timer_i = top->irq_external_i = 0;
  top->mtime_i = 0;
  top->idle_req_i = 0;
  top->eval();

  // PMU idle-handshake model (doc/CPU_SOC_INTERFACE.md): request quiescence
  // while the core sleeps, hold the request for a random time (sometimes
  // raising an interrupt meanwhile), then withdraw it. While idle_ack is high
  // the core must not commit, fetch or issue any AXI transaction.
  int idle_pct = int(plus_u64("idle_pct", 50));
  std::mt19937 idle_rng(uint32_t(seed * 104729 + 7));
  enum { IH_OFF, IH_WAIT_ACK, IH_HOLD, IH_WAIT_DROP } ih = IH_OFF;
  int ih_cnt = 0;
  uint64_t idle_handshakes = 0;
  bool prev_sleep = false;

  AxilPins pins{};
  uint64_t cycle = 0, retired = 0, sleep_cycles = 0, sleep_run = 0, irqs = 0, traps = 0;
  bool done = false, failed = false;
  uint32_t tohost_val = 0;
  uint64_t drain = 0;
  std::string fail_msg;

  for (; cycle < max_cycles; cycle++) {
    // ---------------- low phase: drive inputs ----------------
    top->clk = 0;
    if (cycle == 4) top->rst_n = 1;
    top->mtime_i = cycle / 8;
    if (irq_rate && int(irq_rng() % 10000) < irq_rate) irq_src |= 1u << (irq_rng() % 3);
    if (top->core_sleep_o) {
      sleep_cycles++;
      if (++sleep_run > 2000) irq_src |= 7;  // watchdog wake-up
    } else {
      sleep_run = 0;
    }
    switch (ih) {
      case IH_OFF:
        if (top->core_sleep_o && !prev_sleep && int(idle_rng() % 100) < idle_pct) {
          top->idle_req_i = 1; ih = IH_WAIT_ACK; ih_cnt = 0;
        }
        break;
      case IH_WAIT_ACK:
        if (top->idle_ack_o) { ih = IH_HOLD; ih_cnt = 4 + int(idle_rng() % 60); idle_handshakes++; }
        else if (++ih_cnt > 64) { failed = true; fail_msg = "idle_ack not given within 64 cycles"; }
        break;
      case IH_HOLD:
        if (ih_cnt == 2 && (idle_rng() & 1)) irq_src |= 1u << (idle_rng() % 3);  // wake race
        if (--ih_cnt <= 0) { top->idle_req_i = 0; ih = IH_WAIT_DROP; ih_cnt = 0; }
        break;
      case IH_WAIT_DROP:
        if (!top->idle_ack_o) ih = IH_OFF;
        else if (++ih_cnt > 4) { failed = true; fail_msg = "idle_ack not withdrawn after idle_req"; }
        break;
    }
    prev_sleep = top->core_sleep_o;
    top->irq_software_i = irq_src & 1;
    top->irq_timer_i = (irq_src >> 1) & 1;
    top->irq_external_i = (irq_src >> 2) & 1;

    mem.drive(pins);
    top->m_awready = pins.awready; top->m_wready = pins.wready;
    top->m_bvalid = pins.bvalid; top->m_bresp = pins.bresp;
    top->m_arready = pins.arready; top->m_rvalid = pins.rvalid;
    top->m_rdata = pins.rdata; top->m_rresp = pins.rresp;
    top->eval();

    // ---------------- sample just before the rising edge ----------------
    pins.awvalid = top->m_awvalid; pins.awaddr = top->m_awaddr;
    pins.wvalid = top->m_wvalid; pins.wdata = top->m_wdata; pins.wstrb = top->m_wstrb;
    pins.bready = top->m_bready; pins.arvalid = top->m_arvalid; pins.araddr = top->m_araddr;
    pins.rready = top->m_rready;
    mem.sample(pins);

    if (top->rst_n && top->idle_ack_o &&
        (top->trace_valid_o || top->m_arvalid || top->m_awvalid || top->m_wvalid)) {
      failed = true;
      fail_msg = "activity while idle_ack is asserted at cycle " + std::to_string(cycle);
    }

    if (top->rst_n && top->trace_valid_o && !done) {
      TraceEvent e{};
      e.irq = top->trace_irq_o; e.trap = top->trace_trap_o;
      e.pc = top->trace_pc_o; e.insn = top->trace_insn_o; e.next_pc = top->trace_next_pc_o;
      e.cause = top->trace_cause_o; e.tval = top->trace_tval_o;
      e.rd_we = top->trace_rd_we_o; e.rd = top->trace_rd_o; e.rd_wdata = top->trace_rd_wdata_o;
      e.mem_we = top->trace_mem_we_o; e.mem_re = top->trace_mem_re_o;
      e.mem_addr = top->trace_mem_addr_o; e.mem_wdata = top->trace_mem_wdata_o;
      e.mem_be = top->trace_mem_be_o; e.mip = top->trace_mip_o;
      if (e.irq) irqs++; else if (e.trap) traps++; else retired++;
      cov.sample(e);
      if (trace)
        fprintf(trace, "%10lu %s pc=%08x insn=%08x next=%08x %s x%-2u=%08x mem=%08x\n",
                (unsigned long)cycle, e.irq ? "IRQ " : e.trap ? "TRAP" : "RET ", e.pc, e.insn,
                e.next_pc, e.rd_we ? "W" : "-", e.rd, e.rd_wdata, e.mem_addr);
      if (spike) {
        std::string err;
        if (!spike->step(e, err)) {
          fail_msg = "COSIM MISMATCH at cycle " + std::to_string(cycle) + " (event " +
                     std::to_string(spike->steps()) + "): " + err;
          failed = true;
        }
      }
      if (e.mem_we && (e.mem_addr & ~3u) == tohost) {
        tohost_val = e.mem_wdata;
        done = true;
      }
    }

    // ---------------- rising edge ----------------
    top->clk = 1;
    top->eval();
    mem.commit();
    ctx->timeInc(1);
    if (failed) break;
    if (done && ++drain > 200 && mem.idle()) break;
  }

  if (!failed && !done) { failed = true; fail_msg = "TIMEOUT after " + std::to_string(cycle) + " cycles"; }
  if (!failed && (tohost_val & 0xffff) != 1) {
    failed = true;
    fail_msg = "test reported failure, tohost=" + std::to_string(tohost_val);
  }

  // Final memory image comparison (program must clean the D-cache before tohost).
  if (!failed && memcmp_en && spike) {
    for (uint32_t a = RAM_BASE; a < RAM_BASE + RAM_SIZE; a++) {
      if ((a & ~3u) == tohost) continue;
      uint8_t sv = 0;
      spike->read_mem(a, sv);
      if (*mem.ptr(a) != sv) {
        char b[160];
        snprintf(b, sizeof b, "MEMORY MISMATCH at %08x: rtl=%02x spike=%02x", a, *mem.ptr(a), sv);
        fail_msg = b; failed = true;
        break;
      }
    }
  }

  if (!sig_path.empty()) {
    std::ofstream sf(sig_path);
    uint32_t b = elf.sym("begin_signature"), e = elf.sym("end_signature");
    for (uint32_t a = b; a < e; a += 4) {
      uint8_t* p = mem.ptr(a);
      char w[16];
      snprintf(w, sizeof w, "%08x", p[0] | p[1] << 8 | p[2] << 16 | uint32_t(p[3]) << 24);
      sf << w << "\n";
    }
  }
  if (!cov_path.empty()) cov.write(cov_path);
  if (trace) fclose(trace);

  printf("[tb] idle_handshakes=%lu\n", (unsigned long)idle_handshakes);
  printf("[tb] cycles=%lu retired=%lu traps=%lu irqs=%lu sleep_cycles=%lu axi_rd=%lu axi_wr=%lu axi_err=%lu cosim_steps=%lu\n",
         (unsigned long)cycle, (unsigned long)retired, (unsigned long)traps, (unsigned long)irqs,
         (unsigned long)sleep_cycles, (unsigned long)mem.n_reads, (unsigned long)mem.n_writes,
         (unsigned long)mem.n_errors, (unsigned long)(spike ? spike->steps() : 0));
  if (failed) printf("[tb] FAIL: %s\n", fail_msg.c_str());
  else printf("[tb] PASS\n");

  top->final();
#if VM_COVERAGE
  std::string cdat = plus_str("vcov", "");
  if (!cdat.empty()) ctx->coveragep()->write(cdat.c_str());
#endif
  return failed ? 1 : 0;
}
