// Lockstep co-simulation against Spike (libriscv).
//
// Spike runs as an in-process library behind a custom simif_t that owns its
// own copy of memory. For every commit event reported by the RTL trace port the
// reference is stepped once and the architectural effects are compared:
// pc, next pc, trap cause/tval, interrupt entry, rd write and store data.
#pragma once
#include <cstdint>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

class processor_t;
class cfg_t;

struct TraceEvent {
  bool     irq, trap;
  uint32_t pc, insn, next_pc;
  uint32_t cause, tval;
  bool     rd_we;
  uint32_t rd, rd_wdata;
  bool     mem_we, mem_re;
  uint32_t mem_addr, mem_wdata, mem_be;
  uint32_t mip;      // {MEIP,MTIP,MSIP} as seen by the RTL for this event
};

class SpikeCosim {
 public:
  struct Region { uint32_t base, size; };

  SpikeCosim(const std::string& isa, uint32_t start_pc,
             std::vector<Region> ram, std::vector<Region> mmio, const char* log_path);
  ~SpikeCosim();

  void write_mem(uint32_t addr, uint8_t v);
  bool read_mem(uint32_t addr, uint8_t& v) const;

  // Returns false and fills err on mismatch.
  bool step(const TraceEvent& e, std::string& err);

  uint64_t steps() const { return steps_; }
  uint32_t pc() const;

 private:
  class Sim;
  std::unique_ptr<Sim> sim_;
  uint64_t steps_ = 0;
};
