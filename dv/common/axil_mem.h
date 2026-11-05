// Cycle-based AXI4-Lite slave model for Verilator testbenches.
//
//  * RAM regions (byte array), MMIO device block, everything else -> DECERR
//  * Random READY back-pressure and random response latency
//  * Up to 2 outstanding transactions per direction
//
// Usage per clock cycle (before the rising edge, after inputs settle):
//   drive(outputs) -> eval -> sample(inputs) -> posedge -> commit()
#pragma once
#include <cstdint>
#include <deque>
#include <functional>
#include <random>
#include <vector>

struct AxilPins {
  // master -> slave
  uint8_t awvalid; uint32_t awaddr; uint8_t wvalid; uint32_t wdata; uint8_t wstrb;
  uint8_t bready; uint8_t arvalid; uint32_t araddr; uint8_t rready;
  // slave -> master
  uint8_t awready, wready, bvalid, bresp, arready, rvalid, rresp; uint32_t rdata;
};

class AxilMem {
 public:
  struct Ram { uint32_t base, size; std::vector<uint8_t> data; };
  std::vector<Ram> rams;
  uint32_t mmio_base = 0x40000000, mmio_size = 0x1000;
  // MMIO write hook: (offset, data, strb). Reads of MMIO return 0.
  std::function<void(uint32_t, uint32_t, uint8_t)> on_mmio_write;

  // Randomisation knobs
  int ready_pct = 100;     // probability of READY per cycle
  int max_latency = 0;     // extra response latency in cycles [0, max]
  std::mt19937 rng{1};

  // Statistics
  uint64_t n_reads = 0, n_writes = 0, n_errors = 0;

  void add_ram(uint32_t base, uint32_t size) { rams.push_back({base, size, std::vector<uint8_t>(size, 0)}); }

  uint8_t* ptr(uint32_t a) {
    for (auto& r : rams)
      if (a >= r.base && a - r.base < r.size) return &r.data[a - r.base];
    return nullptr;
  }
  bool is_mmio(uint32_t a) const { return a >= mmio_base && a - mmio_base < mmio_size; }

  void drive(AxilPins& p) {
    p.arready = r_q_.size() < 2 && chance();
    p.awready = aw_q_.size() < 2 && chance();
    p.wready  = w_q_.size() < 2 && chance();
    p.rvalid  = !r_q_.empty() && r_q_.front().ready <= cycle_;
    if (p.rvalid) { p.rdata = r_q_.front().data; p.rresp = r_q_.front().resp; }
    else          { p.rdata = 0; p.rresp = 0; }
    p.bvalid = !b_q_.empty() && b_q_.front().ready <= cycle_;
    p.bresp  = p.bvalid ? b_q_.front().resp : 0;
    drv_ = p;
  }

  // Record handshakes seen just before the edge.
  void sample(const AxilPins& p) {
    ar_hs_ = p.arvalid && drv_.arready;  ar_addr_ = p.araddr;
    r_hs_  = drv_.rvalid && p.rready;
    aw_hs_ = p.awvalid && drv_.awready;  aw_addr_ = p.awaddr;
    w_hs_  = p.wvalid && drv_.wready;    w_data_ = p.wdata; w_strb_ = p.wstrb;
    b_hs_  = drv_.bvalid && p.bready;
  }

  void commit() {
    if (r_hs_) r_q_.pop_front();
    if (b_hs_) b_q_.pop_front();
    if (ar_hs_) {
      Rsp r{0, 0, cycle_ + 1 + lat()};
      uint32_t a = ar_addr_ & ~3u;
      if (uint8_t* m = ptr(a)) { r.data = m[0] | m[1] << 8 | m[2] << 16 | uint32_t(m[3]) << 24; }
      else if (!is_mmio(a)) { r.resp = 3; n_errors++; }
      n_reads++;
      r_q_.push_back(r);
    }
    if (aw_hs_) aw_q_.push_back(aw_addr_);
    if (w_hs_) w_q_.push_back({w_data_, w_strb_});
    while (!aw_q_.empty() && !w_q_.empty()) {
      uint32_t a = aw_q_.front() & ~3u;
      auto [d, st] = w_q_.front();
      aw_q_.pop_front(); w_q_.pop_front();
      Rsp b{0, 0, cycle_ + 1 + lat()};
      if (uint8_t* m = ptr(a)) {
        for (int i = 0; i < 4; i++) if (st >> i & 1) m[i] = uint8_t(d >> (8 * i));
      } else if (is_mmio(a)) {
        if (on_mmio_write) on_mmio_write(a - mmio_base, d, st);
      } else {
        b.resp = 3; n_errors++;
      }
      n_writes++;
      b_q_.push_back(b);
    }
    cycle_++;
  }

  bool idle() const { return r_q_.empty() && b_q_.empty() && aw_q_.empty() && w_q_.empty(); }

 private:
  struct Rsp { uint32_t data; uint8_t resp; uint64_t ready; };
  std::deque<Rsp> r_q_, b_q_;
  std::deque<uint32_t> aw_q_;
  std::deque<std::pair<uint32_t, uint8_t>> w_q_;
  AxilPins drv_{};
  bool ar_hs_ = false, r_hs_ = false, aw_hs_ = false, w_hs_ = false, b_hs_ = false;
  uint32_t ar_addr_ = 0, aw_addr_ = 0, w_data_ = 0;
  uint8_t w_strb_ = 0;
  uint64_t cycle_ = 0;

  bool chance() { return ready_pct >= 100 || int(rng() % 100) < ready_pct; }
  uint64_t lat() { return max_latency ? rng() % (max_latency + 1) : 0; }
};
