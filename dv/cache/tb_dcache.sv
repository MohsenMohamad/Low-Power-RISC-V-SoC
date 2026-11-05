// D-cache constrained-random testbench (Verilator --timing).
//
// Phases: random traffic with interleaved clean/flush, AXI back-pressure and
// latency sweeps, eviction storm on two hot sets, directed write-back error,
// final flush with full memory comparison.
`timescale 1ns/1ps
module tb_dcache;
  import cache_tb_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  axil_if  axi (clk);
  cache_if cif (clk);

  dcache #(.CACHE_BASE(32'h8000_0000), .CACHE_MASK(32'hFFFE_0000)) dut (
    .clk, .rst_n,
    .req_i (cif.req), .gnt_o (cif.gnt), .addr_i (cif.addr), .we_i (cif.we), .be_i (cif.be),
    .wdata_i (cif.wdata), .rvalid_o (cif.rvalid), .rdata_o (cif.rdata), .err_o (cif.err),
    .maint_req_i (cif.maint_req), .maint_inval_i (cif.maint_inval),
    .maint_done_o (cif.maint_done), .wb_err_o (cif.wb_err),
    .m_awvalid (axi.awvalid), .m_awready (axi.awready), .m_awaddr (axi.awaddr), .m_awprot (axi.awprot),
    .m_wvalid (axi.wvalid), .m_wready (axi.wready), .m_wdata (axi.wdata), .m_wstrb (axi.wstrb),
    .m_bvalid (axi.bvalid), .m_bready (axi.bready), .m_bresp (axi.bresp),
    .m_arvalid (axi.arvalid), .m_arready (axi.arready), .m_araddr (axi.araddr), .m_arprot (axi.arprot),
    .m_rvalid (axi.rvalid), .m_rready (axi.rready), .m_rdata (axi.rdata), .m_rresp (axi.rresp),
    .idle_o ()
  );

  // ---------------------------------------------------------------------------
  // SVA: AXI4-Lite master rules and core-port rules
  // ---------------------------------------------------------------------------
  int outstanding;     // core requests accepted but not answered
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) outstanding <= 0;
    else outstanding <= outstanding + int'(cif.req && cif.gnt) - int'(cif.rvalid);

  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
                 axi.arvalid && !axi.arready |=> axi.arvalid && $stable(axi.araddr));
  a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
                 axi.awvalid && !axi.awready |=> axi.awvalid && $stable(axi.awaddr));
  a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n)
                 axi.wvalid && !axi.wready |=> axi.wvalid && $stable(axi.wdata) && $stable(axi.wstrb));
  a_no_x:      assert property (@(posedge clk) disable iff (!rst_n)
                 !$isunknown({axi.arvalid, axi.awvalid, axi.wvalid, axi.rready, axi.bready,
                              cif.gnt, cif.rvalid, cif.maint_done}));
  a_aligned:   assert property (@(posedge clk) disable iff (!rst_n)
                 (axi.arvalid -> axi.araddr[1:0] == 0) && (axi.awvalid -> axi.awaddr[1:0] == 0));
  a_one_out:   assert property (@(posedge clk) disable iff (!rst_n) outstanding <= 1);
  a_rsp_req:   assert property (@(posedge clk) disable iff (!rst_n) cif.rvalid |-> outstanding == 1);
  a_no_gnt_mt: assert property (@(posedge clk) disable iff (!rst_n) cif.maint_req |-> !cif.gnt);
  a_done_req:  assert property (@(posedge clk) disable iff (!rst_n) cif.maint_done |-> cif.maint_req);
  a_wstrb:     assert property (@(posedge clk) disable iff (!rst_n) axi.wvalid |-> axi.wstrb != 0);

  // ---------------------------------------------------------------------------
  // Functional coverage
  // ---------------------------------------------------------------------------
  wire       lookup    = dut.state_q == 5'd1;
  wire       is_store  = dut.rq_we_q;
  wire       hit       = dut.hit;
  wire       victim_d  = dut.valid_q[dut.victim_sel][dut.rq_idx] && dut.dirty_q[dut.victim_sel][dut.rq_idx];
  wire [3:0] st_be     = dut.rq_be_q;
  wire       both_valid = dut.valid_q[0][dut.rq_idx] && dut.valid_q[1][dut.rq_idx];

  covergroup cg_lookup @(posedge clk iff (rst_n && lookup));
    cp_op:     coverpoint is_store { bins load = {0}; bins store = {1}; }
    cp_hit:    coverpoint hit      { bins miss = {0}; bins hit = {1}; }
    cp_way:    coverpoint dut.hit_way iff (hit) { bins way0 = {0}; bins way1 = {1}; }
    cp_victim: coverpoint {victim_d, dut.victim_sel, both_valid} iff (!hit) {
      bins invalid_way0 = {3'b000}; bins invalid_way1 = {3'b010};
      bins clean_lru0   = {3'b001}; bins clean_lru1   = {3'b011};
      bins dirty_lru0   = {3'b101}; bins dirty_lru1   = {3'b111};
    }
    cp_be:     coverpoint st_be iff (is_store) {
      bins b0 = {4'b0001}; bins b1 = {4'b0010}; bins b2 = {4'b0100}; bins b3 = {4'b1000};
      bins h0 = {4'b0011}; bins h1 = {4'b1100}; bins w = {4'b1111};
    }
    cp_op_hit: coverpoint {is_store, hit} {
      bins load_miss = {2'b00}; bins load_hit = {2'b01}; bins store_miss = {2'b10}; bins store_hit = {2'b11};
    }
  endgroup
  cg_lookup cg_l = new;

  covergroup cg_axi @(posedge clk iff rst_n);
    cp_ar_wait: coverpoint {axi.arvalid, axi.arready} { bins wait_ = {2'b10}; bins hs = {2'b11}; }
    cp_aw_w:    coverpoint {axi.awvalid & axi.awready, axi.wvalid & axi.wready} {
      bins aw_only = {2'b10}; bins w_only = {2'b01}; bins both = {2'b11}; }
    cp_rresp:   coverpoint axi.rresp iff (axi.rvalid && axi.rready) {
      bins okay = {2'b00}; bins slverr = {2'b10}; bins decerr = {2'b11}; }
    cp_bresp:   coverpoint axi.bresp iff (axi.bvalid && axi.bready) {
      bins okay = {2'b00}; bins slverr = {2'b10}; bins decerr = {2'b11}; }
  endgroup
  cg_axi cg_a = new;

  covergroup cg_rsp @(posedge clk iff (rst_n && cif.rvalid));
    cp_err:   coverpoint {dut.rq_we_q, cif.err} {
      bins load_ok = {2'b00}; bins load_err = {2'b01}; bins store_ok = {2'b10}; bins store_err = {2'b11}; }
    cp_unc:   coverpoint (dut.state_q == 5'd9 || dut.state_q == 5'd11) { bins cached = {0}; bins uncached = {1}; }
    cp_b2b:   coverpoint (cif.req && cif.gnt) { bins pipelined_accept = {1}; bins no_accept = {0}; }
  endgroup
  cg_rsp cg_r = new;

  covergroup cg_maint @(posedge clk iff (rst_n && cif.maint_done));
    cp_kind:   coverpoint cif.maint_inval { bins clean = {0}; bins flush = {1}; }
    cp_dirty:  coverpoint ndirty_at_start { bins none = {0}; bins few = {[1:8]}; bins many = {[9:$]}; }
    cp_wb_err: coverpoint cif.wb_err { bins ok = {0}; bins err = {1}; }
  endgroup
  cg_maint cg_m = new;

  int ndirty_at_start;
  always @(posedge clk)
    if (cif.maint_req && dut.state_q == 5'd0) begin
      ndirty_at_start = 0;
      for (int w = 0; w < 2; w++)
        for (int s = 0; s < 128; s++)
          ndirty_at_start += int'(dut.valid_q[w][s] && dut.dirty_q[w][s]);
    end

  c_hit_then_accept: cover property (@(posedge clk) disable iff (!rst_n) lookup && hit && cif.req && cif.gnt);
  c_store_then_load: cover property (@(posedge clk) disable iff (!rst_n)
                       lookup && hit && is_store ##1 cif.req && cif.gnt && !cif.we ##1 lookup && hit);
  c_evict_dirty:     cover property (@(posedge clk) disable iff (!rst_n) lookup && !hit && victim_d);
  c_flush_dirty:     cover property (@(posedge clk) disable iff (!rst_n) dut.state_q == 5'd12 && dut.fl_line_dirty);
  c_last_line_dirty: cover property (@(posedge clk) disable iff (!rst_n) dut.state_q == 5'd12 && dut.fl_line_dirty && dut.fl_last);
  c_retract:         cover property (@(posedge clk) disable iff (!rst_n) cif.req && !cif.gnt ##1 !cif.req);

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  axil_slave  slv;
  cache_agent agt;

  initial begin
    int unsigned seed;
    int n;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("n=%d", n)) n = 20000;
    process::self().srandom(seed);
    $display("[tb_dcache] seed=%0d n=%0d", seed, n);

    cif.req = 0; cif.we = 0; cif.addr = 0; cif.be = 0; cif.wdata = 0;
    cif.maint_req = 0; cif.maint_inval = 0;
    slv = new(axi);
    agt = new("dcache", cif, slv, 0);
    fork slv.run(); join_none
    repeat (5) @(negedge clk);
    rst_n = 1;

    // 1. baseline random traffic, no back-pressure
    agt.traffic(n / 4, 0);
    agt.maint(0);
    // 2. back-pressure and latency, interleaved maintenance
    slv.ready_pct = 60; slv.max_lat = 4;
    agt.traffic(n / 4, 25);
    // 3. eviction storm: only the two hot sets
    slv.ready_pct = 90; slv.max_lat = 1;
    // the weighted region choice is switched off while the mode pins the region
    agt.tx.c_region.constraint_mode(0);
    agt.tx.hot_only = 1;
    agt.traffic(n / 4, 15);
    agt.tx.hot_only = 0;
    agt.tx.c_region.constraint_mode(1);
    // 4. directed write-back error: dirty a line, poison its writes, clean
    begin
      bit [31:0] a = CACHE_BASE + 32'h0000_3F00;
      cache_txn t = new();
      agt.maint(1);
      t.region = R_RANDOM; t.we = 1; t.size = 2; t.boff = 0; t.wdata = 32'hDEAD_BEEF;
      t.tag = 6'd7; t.set = 7'h70; t.word = 0; t.gap = 0; t.retract = 0;
      t.finalize(0);
      a = t.addr;
      // drive the single store directly
      @(negedge clk);
      cif.req = 1; cif.addr = t.addr; cif.we = 1; cif.be = 4'hF; cif.wdata = t.wdata;
      do begin #1; if (!cif.gnt) @(negedge clk); end while (!cif.gnt);
      @(negedge clk); cif.req = 0;
      while (!cif.rvalid) begin #1; if (!cif.rvalid) @(negedge clk); end
      agt.check(t, cif.rdata, cif.err);
      slv.wr_poison[{a[31:4], 4'h0}] = 1;
      for (int i = 0; i < 4; i++) agt.lost[{a[31:4], 4'h0} + 4 * i] = 1;
      agt.maint(0);
      if (cif.wb_err !== 1'b1) agt.fail("wb_err not reported after failed write-back");
      slv.wr_poison.delete();
      agt.maint(0);
      if (cif.wb_err !== 1'b0) agt.fail("wb_err not cleared by next maintenance");
      agt.tx = new();
    end
    // 5. mixed traffic with random latency, then final flush + full compare
    slv.ready_pct = 75; slv.max_lat = 3;
    agt.traffic(n / 4, 10);
    agt.maint(1);

    agt.report();
    if (agt.n_mismatch == 0) $display("[tb_dcache] PASS");
    else $display("[tb_dcache] FAIL mismatches=%0d", agt.n_mismatch);
    $finish;
  end

  initial begin
    int unsigned max_cycles;
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 5_000_000;
    repeat (max_cycles) @(posedge clk);
    $display("[tb_dcache] FAIL timeout");
    $finish;
  end
endmodule
