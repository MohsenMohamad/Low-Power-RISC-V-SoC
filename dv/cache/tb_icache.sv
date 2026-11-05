// I-cache constrained-random testbench (Verilator --timing).
//
// Phases: random fetch traffic (hot sets, sequential runs, uncached, error
// window, poisoned lines, request retraction), back-pressure sweep, coherence
// scenario (backing memory modified behind the cache: stale data tolerated
// until invalidation, new data required after it), invalidation under traffic.
`timescale 1ns/1ps
module tb_icache;
  import cache_tb_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  axil_if  axi (clk);
  cache_if cif (clk);

  icache #(
    .CACHE0_BASE (32'h0000_0000), .CACHE0_MASK (32'hFFFF_C000),
    .CACHE1_BASE (32'h8000_0000), .CACHE1_MASK (32'hFFFE_0000)
  ) dut (
    .clk, .rst_n,
    .req_i (cif.req), .gnt_o (cif.gnt), .addr_i (cif.addr),
    .rvalid_o (cif.rvalid), .rdata_o (cif.rdata), .err_o (cif.err),
    .inval_req_i (cif.maint_req), .inval_done_o (cif.maint_done),
    .m_awvalid (axi.awvalid), .m_awready (axi.awready), .m_awaddr (axi.awaddr), .m_awprot (axi.awprot),
    .m_wvalid (axi.wvalid), .m_wready (axi.wready), .m_wdata (axi.wdata), .m_wstrb (axi.wstrb),
    .m_bvalid (axi.bvalid), .m_bready (axi.bready), .m_bresp (axi.bresp),
    .m_arvalid (axi.arvalid), .m_arready (axi.arready), .m_araddr (axi.araddr), .m_arprot (axi.arprot),
    .m_rvalid (axi.rvalid), .m_rready (axi.rready), .m_rdata (axi.rdata), .m_rresp (axi.rresp),
    .idle_o ()
  );
  assign cif.wb_err = 1'b0;

  // ---------------------------------------------------------------------------
  // SVA
  // ---------------------------------------------------------------------------
  int outstanding;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) outstanding <= 0;
    else outstanding <= outstanding + int'(cif.req && cif.gnt) - int'(cif.rvalid);

  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
                 axi.arvalid && !axi.arready |=> axi.arvalid && $stable(axi.araddr));
  a_no_write:  assert property (@(posedge clk) disable iff (!rst_n) !axi.awvalid && !axi.wvalid);
  a_instr_prot:assert property (@(posedge clk) disable iff (!rst_n) axi.arvalid |-> axi.arprot[2]);
  a_no_x:      assert property (@(posedge clk) disable iff (!rst_n)
                 !$isunknown({axi.arvalid, axi.rready, cif.gnt, cif.rvalid, cif.maint_done}));
  a_one_out:   assert property (@(posedge clk) disable iff (!rst_n) outstanding <= 1);
  a_rsp_req:   assert property (@(posedge clk) disable iff (!rst_n) cif.rvalid |-> outstanding == 1);
  a_inv_gnt:   assert property (@(posedge clk) disable iff (!rst_n) cif.maint_req |-> !cif.gnt);
  a_done_req:  assert property (@(posedge clk) disable iff (!rst_n) cif.maint_done |-> cif.maint_req);
  // After invalidation completes every line is invalid
  a_inv_all:   assert property (@(posedge clk) disable iff (!rst_n)
                 cif.maint_done |=> (dut.valid_q[0] == '0) && (dut.valid_q[1] == '0));

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  wire lookup = dut.state_q == 3'd1;
  wire both_valid = dut.valid_q[0][dut.rq_idx] && dut.valid_q[1][dut.rq_idx];

  covergroup cg_lookup @(posedge clk iff (rst_n && lookup));
    cp_hit:    coverpoint dut.hit { bins miss = {0}; bins hit = {1}; }
    cp_way:    coverpoint dut.hit_way iff (dut.hit) { bins way0 = {0}; bins way1 = {1}; }
    cp_victim: coverpoint {dut.victim_sel, both_valid} iff (!dut.hit) {
      bins invalid0 = {2'b00}; bins invalid1 = {2'b10}; bins lru0 = {2'b01}; bins lru1 = {2'b11}; }
    cp_accept: coverpoint (dut.hit && cif.req && cif.gnt) { bins pipelined = {1}; bins single = {0}; }
  endgroup
  cg_lookup cg_l = new;

  covergroup cg_rsp @(posedge clk iff (rst_n && cif.rvalid));
    cp_kind: coverpoint {dut.state_q == 3'd6, cif.err} {
      bins cached_ok = {2'b00}; bins cached_err = {2'b01}; bins uncached_ok = {2'b10}; bins uncached_err = {2'b11}; }
  endgroup
  cg_rsp cg_r = new;

  covergroup cg_inval @(posedge clk iff (rst_n && cif.maint_done));
    cp_lines: coverpoint nvalid { bins empty = {0}; bins few = {[1:32]}; bins many = {[33:$]}; }
  endgroup
  cg_inval cg_i = new;
  int nvalid;
  always_comb begin
    nvalid = 0;
    for (int w = 0; w < 2; w++) for (int s = 0; s < 128; s++) nvalid += int'(dut.valid_q[w][s]);
  end

  c_hit_then_accept: cover property (@(posedge clk) disable iff (!rst_n) lookup && dut.hit && cif.req && cif.gnt);
  c_miss_refill_err: cover property (@(posedge clk) disable iff (!rst_n) cif.rvalid && cif.err && dut.state_q == 3'd3);
  c_retract:         cover property (@(posedge clk) disable iff (!rst_n) cif.req && !cif.gnt ##1 !cif.req);
  c_inval_after_hit: cover property (@(posedge clk) disable iff (!rst_n) lookup && dut.hit ##1 cif.maint_req);


  // ---------------------------------------------------------------------------
  // Replacement-policy reference model (sampled mid-cycle on stable state)
  // ---------------------------------------------------------------------------
  repl_model repl = new("icache");
  logic [2:0] prev_state;
  always @(negedge clk) begin
    if (!rst_n) begin
      prev_state <= 3'd0;
    end else begin
      if (lookup && prev_state != 3'd4) repl.lookup(dut.rq_addr_q, dut.hit, dut.hit_way, dut.victim_sel);
      if (dut.state_q == 3'd4) repl.filled();                       // REPLAY: refill succeeded
      if (cif.maint_done) repl.inval_all();
      prev_state <= dut.state_q;
    end
  end

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
    $display("[tb_icache] seed=%0d n=%0d", seed, n);

    cif.req = 0; cif.we = 0; cif.addr = 0; cif.be = 4'hF; cif.wdata = 0;
    cif.maint_req = 0; cif.maint_inval = 1;
    slv = new(axi);
    agt = new("icache", cif, slv, 1);
    fork slv.run(); join_none
    repeat (5) @(negedge clk);
    rst_n = 1;

    // 1. random fetch traffic
    agt.traffic(n / 4, 0);
    // 2. back-pressure / latency with invalidations interleaved
    slv.ready_pct = 60; slv.max_lat = 4;
    agt.traffic(n / 4, 25);
    // 3. coherence: change memory behind the cache, then invalidate
    slv.ready_pct = 85; slv.max_lat = 2;
    for (int round = 0; round < 4; round++) begin
      // warm the hot sets so modified words are likely to be cached
      agt.tx.c_region.constraint_mode(0);
      agt.tx.hot_only = 1;
      agt.traffic(n / 32, 0);
      agt.tx.hot_only = 0;
      agt.tx.c_region.constraint_mode(1);
      for (int k = 0; k < 64; k++) begin
        // (block variables in an initial are static: assign, don't initialise)
        bit [31:0] a, oldv, newv;
        a    = CACHE_BASE + {15'b0, 6'($urandom_range(7)), (k % 2) ? 7'd5 : 7'd77,
                             2'($urandom_range(3)), 2'b00};
        oldv = agt.model(a);
        newv = $urandom();
        if (!agt.stale.exists(a)) agt.stale[a] = oldv;
        agt.refm[a] = newv;
        slv.poke(a, newv);
      end
      agt.tx.c_region.constraint_mode(0);
      agt.tx.hot_only = 1;
      agt.traffic(n / 32, 0);      // stale values tolerated here
      agt.tx.hot_only = 0;
      agt.tx.c_region.constraint_mode(1);
      agt.maint(1);                // invalidate: new values required from now on
      agt.traffic(n / 32, 0);
    end
    // 4. eviction storm with invalidations
    agt.tx.c_region.constraint_mode(0);
    agt.tx.hot_only = 1;
    agt.traffic(n / 4, 15);
    agt.tx.hot_only = 0;
    agt.tx.c_region.constraint_mode(1);

    agt.report();
    repl.report();
    agt.n_mismatch += repl.n_errors;
    if (agt.n_mismatch == 0) $display("[tb_icache] PASS");
    else $display("[tb_icache] FAIL mismatches=%0d", agt.n_mismatch);
    $finish;
  end

  initial begin
    int unsigned max_cycles;
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 5_000_000;
    repeat (max_cycles) @(posedge clk);
    $display("[tb_icache] FAIL timeout");
    $finish;
  end
endmodule
