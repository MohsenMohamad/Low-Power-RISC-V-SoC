// AXI4-Lite protocol checker (ARM IHI 0022 rules for the -Lite subset) plus
// the latency contract of the debug blocks (ONE_CYCLE: a request accepted
// in cycle t is answered in t+1, needed behind the zero-wait external port).
// Bind it to any AXI4-Lite slave port; master-side rules are assertions on
// the testbench BFM, slave-side rules are assertions on the DUT.
module dbg_axil_sva #(
  parameter int unsigned AW = 12,
  parameter bit ONE_CYCLE = 1'b1
) (
  input logic          clk,
  input logic          rst_n,
  input logic [AW-1:0] awaddr,
  input logic          awvalid, awready,
  input logic [31:0]   wdata,
  input logic [3:0]    wstrb,
  input logic          wvalid, wready,
  input logic [1:0]    bresp,
  input logic          bvalid, bready,
  input logic [AW-1:0] araddr,
  input logic          arvalid, arready,
  input logic [31:0]   rdata,
  input logic [1:0]    rresp,
  input logic          rvalid, rready
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // outstanding transaction bookkeeping
  int unsigned n_aw, n_w, n_b, n_ar, n_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin n_aw <= 0; n_w <= 0; n_b <= 0; n_ar <= 0; n_r <= 0; end
    else begin
      n_aw <= n_aw + 32'(awvalid && awready);
      n_w  <= n_w  + 32'(wvalid && wready);
      n_b  <= n_b  + 32'(bvalid && bready);
      n_ar <= n_ar + 32'(arvalid && arready);
      n_r  <= n_r  + 32'(rvalid && rready);
    end
  end

  // ---- reset ----
  // Checked during reset, so it must not be disabled by reset: the default
  // "disable iff (!rst_n)" would make it vacuous (doc/SPEC.md: assertions may
  // not be disabled by the condition they check; negative test neg_axil_rst).
  // From the third clock edge of a reset on (the blocks' reset synchronisers
  // need two edges to propagate a reset that is asserted at time 0).
  int unsigned n_rst_edges;
  always @(posedge clk) n_rst_edges <= rst_n ? 0 : n_rst_edges + 1;
  a_rst_valid: assert property (@(posedge clk) disable iff (1'b0)
                                !rst_n && n_rst_edges >= 2 |-> !bvalid && !rvalid);
  // ---- no X on handshake signals ----
  a_noX: assert property (!$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid,
                                       awready, wready, bready, arready, rready}));
  // ---- master: VALID held and payload stable until READY ----
  a_aw_hold: assert property (awvalid && !awready |=> awvalid && $stable(awaddr));
  a_w_hold:  assert property (wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb));
  a_ar_hold: assert property (arvalid && !arready |=> arvalid && $stable(araddr));
  // ---- slave: response held and stable until READY ----
  a_b_hold:  assert property (bvalid && !bready |=> bvalid && $stable(bresp));
  a_r_hold:  assert property (rvalid && !rready |=> rvalid && $stable(rdata) && $stable(rresp));
  // ---- slave: no response without a request ----
  a_b_after_req: assert property (bvalid |-> (n_b < n_aw) && (n_b < n_w));
  a_r_after_req: assert property (rvalid |-> n_r < n_ar);
  a_resp_legal:  assert property ((bvalid |-> bresp inside {2'b00, 2'b10}) and
                                  (rvalid |-> rresp inside {2'b00, 2'b10}));
  a_r_data_known: assert property (rvalid |-> !$isunknown(rdata));
  // ---- one outstanding transaction per channel ----
  a_one_w: assert property (n_aw - n_b <= 1 && n_w - n_b <= 1);
  a_one_r: assert property (n_ar - n_r <= 1);
  // ---- latency contract ----
  if (ONE_CYCLE) begin : g_lat
    a_r_lat: assert property (arvalid && arready |=> rvalid);
    a_idle_ready: assert property (n_ar == n_r && !rvalid |-> arready);
  end

  // ---- coverage ----
  c_w_same:     cover property (awvalid && wvalid && awready && wready);
  c_aw_first:   cover property (awvalid && awready && !(wvalid && wready));
  c_w_first:    cover property (wvalid && wready && !(awvalid && awready));
  c_b_stall:    cover property (bvalid && !bready ##1 bvalid && bready);
  c_r_stall:    cover property (rvalid && !rready ##1 rvalid && rready);
  c_slverr_w:   cover property (bvalid && bready && bresp == 2'b10);
  c_slverr_r:   cover property (rvalid && rready && rresp == 2'b10);
  c_b2b_read:   cover property (rvalid && rready ##1 arvalid && arready);
endmodule
