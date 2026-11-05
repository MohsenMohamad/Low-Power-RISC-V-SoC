// AXI4-Lite 2:1 mux constrained-random testbench (Verilator --timing).
//
// Two random masters (one read and one write outstanding each, random VALID
// timing and random RREADY/BREADY back-pressure, which the caches never
// produce) share one axil_slave memory. Each master owns a disjoint address
// window, so every read response can be predicted from that master's model.
`timescale 1ns/1ps

package axil_mux_tb_pkg;
  import cache_tb_pkg::*;

  class mux_txn;
    rand bit        we;
    rand bit [7:0]  word;
    rand bit [31:0] data;
    rand bit [3:0]  strb;
    rand bit [3:0]  gap;
    rand bit [6:0]  gsel;
    constraint c_strb { strb != 0; }
    constraint c_gap  { gsel < 100;
                        gsel <  60            -> gap == 0;
                        gsel inside {[60:89]} -> gap inside {[1:3]};
                        gsel >= 90            -> gap inside {[4:15]}; }
  endclass

  class axil_master;
    virtual axil_if vif;
    int        id;
    bit [31:0] base;
    bit [31:0] model [bit [31:0]];
    axil_slave slv;
    mux_txn    tx = new();
    int        rready_pct = 70, bready_pct = 70;
    int        n_rd, n_wr, n_err;
    // outstanding state
    bit        ar_pend, aw_pend, w_pend, rd_out, wr_out;
    bit [31:0] rd_addr;

    function new(int i, virtual axil_if v, axil_slave s);
      id = i; vif = v; slv = s;
      base = 32'h8000_0000 + (i << 16);
    endfunction

    function bit [31:0] expect_word(bit [31:0] a);
      return model.exists(a) ? model[a] : slv.peek(a);
    endfunction

    task run(int n);
      int gap = 0;
      vif.arvalid = 0; vif.awvalid = 0; vif.wvalid = 0; vif.rready = 0; vif.bready = 0;
      vif.araddr = 0; vif.awaddr = 0; vif.wdata = 0; vif.wstrb = 0; vif.arprot = 0; vif.awprot = 0;
      while (n_rd + n_wr < n || rd_out || wr_out || ar_pend || aw_pend || w_pend) begin
        @(negedge vif.clk);
        if (gap > 0) gap--;
        else if (n_rd + n_wr < n && !ar_pend && !rd_out && !aw_pend && !w_pend && !wr_out) begin
          if (!tx.randomize()) $fatal(1, "randomize");
          gap = tx.gap;
          if (tx.we) begin
            bit [31:0] a = base + {22'b0, tx.word, 2'b00};
            bit [31:0] d = expect_word(a);
            for (int i = 0; i < 4; i++) if (tx.strb[i]) d[8*i +: 8] = tx.data[8*i +: 8];
            model[a] = d;
            vif.awaddr = a; vif.wdata = tx.data; vif.wstrb = tx.strb;
            aw_pend = 1; w_pend = 1;
          end else begin
            rd_addr = base + {22'b0, tx.word, 2'b00};
            vif.araddr = rd_addr;
            ar_pend = 1;
          end
        end
        vif.arvalid = ar_pend;
        vif.awvalid = aw_pend;
        vif.wvalid  = w_pend;
        vif.rready  = ($urandom_range(99) < rready_pct);
        vif.bready  = ($urandom_range(99) < bready_pct);
        #1;
        if (vif.arvalid && vif.arready) begin ar_pend = 0; rd_out = 1; end
        if (vif.awvalid && vif.awready) aw_pend = 0;
        if (vif.wvalid && vif.wready)   w_pend = 0;
        if (!aw_pend && !w_pend && (vif.awvalid || vif.wvalid) && !wr_out) wr_out = 1;
        if (vif.rvalid && vif.rready) begin
          if (!rd_out) begin n_err++; $error("[m%0d] unexpected R", id); end
          else if (vif.rdata !== expect_word(rd_addr) || vif.rresp != 0) begin
            n_err++;
            $error("[m%0d] read data addr=%h got=%h exp=%h resp=%0d", id, rd_addr, vif.rdata,
                   expect_word(rd_addr), vif.rresp);
          end
          rd_out = 0; n_rd++;
        end
        if (vif.bvalid && vif.bready) begin
          if (!wr_out) begin n_err++; $error("[m%0d] unexpected B", id); end
          wr_out = 0; n_wr++;
        end
      end
      @(negedge vif.clk);
      vif.rready = 0; vif.bready = 0;
    endtask

    function void check_memory();
      foreach (model[a])
        if (slv.peek(a) != model[a]) begin
          n_err++;
          $error("[m%0d] memory addr=%h mem=%h model=%h", id, a, slv.peek(a), model[a]);
        end
    endfunction
  endclass
endpackage

module tb_axil_mux;
  import cache_tb_pkg::*;
  import axil_mux_tb_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  axil_if s0 (clk), s1 (clk), m (clk);

  axil_mux2 dut (
    .clk, .rst_n,
    .s_awvalid ({s1.awvalid, s0.awvalid}), .s_awready ({s1.awready, s0.awready}),
    .s_awaddr  ({s1.awaddr,  s0.awaddr}),  .s_awprot  ({s1.awprot,  s0.awprot}),
    .s_wvalid  ({s1.wvalid,  s0.wvalid}),  .s_wready  ({s1.wready,  s0.wready}),
    .s_wdata   ({s1.wdata,   s0.wdata}),   .s_wstrb   ({s1.wstrb,   s0.wstrb}),
    .s_bvalid  ({s1.bvalid,  s0.bvalid}),  .s_bready  ({s1.bready,  s0.bready}),
    .s_bresp   ({s1.bresp,   s0.bresp}),
    .s_arvalid ({s1.arvalid, s0.arvalid}), .s_arready ({s1.arready, s0.arready}),
    .s_araddr  ({s1.araddr,  s0.araddr}),  .s_arprot  ({s1.arprot,  s0.arprot}),
    .s_rvalid  ({s1.rvalid,  s0.rvalid}),  .s_rready  ({s1.rready,  s0.rready}),
    .s_rdata   ({s1.rdata,   s0.rdata}),   .s_rresp   ({s1.rresp,   s0.rresp}),
    .m_awvalid (m.awvalid), .m_awready (m.awready), .m_awaddr (m.awaddr), .m_awprot (m.awprot),
    .m_wvalid  (m.wvalid),  .m_wready  (m.wready),  .m_wdata  (m.wdata),  .m_wstrb  (m.wstrb),
    .m_bvalid  (m.bvalid),  .m_bready  (m.bready),  .m_bresp  (m.bresp),
    .m_arvalid (m.arvalid), .m_arready (m.arready), .m_araddr (m.araddr), .m_arprot (m.arprot),
    .m_rvalid  (m.rvalid),  .m_rready  (m.rready),  .m_rdata  (m.rdata),  .m_rresp  (m.rresp)
  );

  // SVA on the downstream (master) side and per-port response routing
  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
                 m.arvalid && !m.arready |=> m.arvalid && $stable(m.araddr));
  a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
                 m.awvalid && !m.awready |=> m.awvalid && $stable(m.awaddr));
  a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n)
                 m.wvalid && !m.wready |=> m.wvalid && $stable(m.wdata) && $stable(m.wstrb));
  a_r_route:   assert property (@(posedge clk) disable iff (!rst_n)
                 !(s0.rvalid && s1.rvalid) && !(s0.bvalid && s1.bvalid));
  a_r_hs:      assert property (@(posedge clk) disable iff (!rst_n)
                 (m.rvalid && m.rready) == ((s0.rvalid && s0.rready) || (s1.rvalid && s1.rready)));
  a_b_hs:      assert property (@(posedge clk) disable iff (!rst_n)
                 (m.bvalid && m.bready) == ((s0.bvalid && s0.bready) || (s1.bvalid && s1.bready)));

  c_both_read:   cover property (@(posedge clk) disable iff (!rst_n) s0.arvalid && s1.arvalid);
  c_both_write:  cover property (@(posedge clk) disable iff (!rst_n) s0.awvalid && s1.awvalid);
  c_r_stalled:   cover property (@(posedge clk) disable iff (!rst_n) m.rvalid && !m.rready);
  c_b_stalled:   cover property (@(posedge clk) disable iff (!rst_n) m.bvalid && !m.bready);
  c_rd_wr_overlap: cover property (@(posedge clk) disable iff (!rst_n) m.rvalid && m.bvalid);

  covergroup cg_grant @(posedge clk iff rst_n);
    cp_rd_owner: coverpoint dut.rd_own_q iff (m.arvalid && m.arready) { bins m0 = {0}; bins m1 = {1}; }
    cp_wr_owner: coverpoint dut.wr_own_q iff (m.awvalid && m.awready) { bins m0 = {0}; bins m1 = {1}; }
    cp_aw_w:     coverpoint {m.awvalid & m.awready, m.wvalid & m.wready} {
      bins aw_first = {2'b10}; bins w_first = {2'b01}; bins together = {2'b11}; }
  endgroup
  cg_grant cg = new;

  axil_slave  slv;
  axil_master mst0, mst1;

  initial begin
    int unsigned seed;
    int n;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("n=%d", n)) n = 4000;
    process::self().srandom(seed);
    $display("[tb_axilmux] seed=%0d n=%0d", seed, n);
    slv = new(m);
    slv.ready_pct = 70; slv.max_lat = 3;
    mst0 = new(0, s0, slv);
    mst1 = new(1, s1, slv);
    fork slv.run(); join_none
    repeat (5) @(negedge clk);
    rst_n = 1;
    fork
      mst0.run(n / 2);
      mst1.run(n / 2);
    join
    mst0.check_memory();
    mst1.check_memory();
    $display("[axilmux] m0: reads=%0d writes=%0d errors=%0d | m1: reads=%0d writes=%0d errors=%0d",
             mst0.n_rd, mst0.n_wr, mst0.n_err, mst1.n_rd, mst1.n_wr, mst1.n_err);
    if (mst0.n_err + mst1.n_err == 0) $display("[tb_axilmux] PASS");
    else $display("[tb_axilmux] FAIL");
    $finish;
  end

  initial begin
    repeat (2_000_000) @(posedge clk);
    $display("[tb_axilmux] FAIL timeout");
    $finish;
  end
endmodule
