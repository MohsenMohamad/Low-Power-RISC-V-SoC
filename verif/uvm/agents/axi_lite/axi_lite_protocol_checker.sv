// -----------------------------------------------------------------------------
// axi_lite_protocol_checker.sv - AXI4-Lite protocol assertions and covers
//
// Bound to every axi_lite_if instance (see tb/axi_lite_bind.sv). Checks the
// AMBA AXI4 (IHI0022) rules that apply to AXI4-Lite:
//   * VALID must stay asserted, and payload stable, until the handshake
//   * no X/Z on VALID/READY out of reset, no X/Z on payload while VALID
//   * all VALIDs low while ARESETn is asserted
//   * B only after both AW and W handshakes of that write; R only after AR
//   * EXOKAY is not a legal AXI4-Lite response
//   * bounded response latency (MAX_WAIT cycles; 0 disables)
// -----------------------------------------------------------------------------
module axi_lite_protocol_checker #(
  parameter int unsigned MAX_WAIT = 256
) (
  input logic        aclk,
  input logic        aresetn,
  input logic [31:0] awaddr,
  input logic [2:0]  awprot,
  input logic        awvalid,
  input logic        awready,
  input logic [31:0] wdata,
  input logic [3:0]  wstrb,
  input logic        wvalid,
  input logic        wready,
  input logic [1:0]  bresp,
  input logic        bvalid,
  input logic        bready,
  input logic [31:0] araddr,
  input logic [2:0]  arprot,
  input logic        arvalid,
  input logic        arready,
  input logic [31:0] rdata,
  input logic [1:0]  rresp,
  input logic        rvalid,
  input logic        rready
);

  localparam logic [1:0] EXOKAY = 2'b01;

  // ---------------------------------------------------------------------------
  // Handshake stability: once VALID is high it stays high with stable payload
  // until READY.
  // ---------------------------------------------------------------------------
  property p_hold(logic valid, logic ready);
    @(posedge aclk) disable iff (!aresetn)
      (valid && !ready) |=> valid;
  endproperty

  a_aw_hold: assert property (p_hold(awvalid, awready)) else $error("AXI-L: AWVALID dropped before AWREADY");
  a_w_hold:  assert property (p_hold(wvalid,  wready))  else $error("AXI-L: WVALID dropped before WREADY");
  a_b_hold:  assert property (p_hold(bvalid,  bready))  else $error("AXI-L: BVALID dropped before BREADY");
  a_ar_hold: assert property (p_hold(arvalid, arready)) else $error("AXI-L: ARVALID dropped before ARREADY");
  a_r_hold:  assert property (p_hold(rvalid,  rready))  else $error("AXI-L: RVALID dropped before RREADY");

  a_aw_stable: assert property (@(posedge aclk) disable iff (!aresetn)
      (awvalid && !awready) |=> ($stable(awaddr) && $stable(awprot)))
    else $error("AXI-L: AW payload changed while AWVALID && !AWREADY");
  a_w_stable: assert property (@(posedge aclk) disable iff (!aresetn)
      (wvalid && !wready) |=> ($stable(wdata) && $stable(wstrb)))
    else $error("AXI-L: W payload changed while WVALID && !WREADY");
  a_b_stable: assert property (@(posedge aclk) disable iff (!aresetn)
      (bvalid && !bready) |=> $stable(bresp))
    else $error("AXI-L: BRESP changed while BVALID && !BREADY");
  a_ar_stable: assert property (@(posedge aclk) disable iff (!aresetn)
      (arvalid && !arready) |=> ($stable(araddr) && $stable(arprot)))
    else $error("AXI-L: AR payload changed while ARVALID && !ARREADY");
  a_r_stable: assert property (@(posedge aclk) disable iff (!aresetn)
      (rvalid && !rready) |=> ($stable(rdata) && $stable(rresp)))
    else $error("AXI-L: R payload changed while RVALID && !RREADY");

  // ---------------------------------------------------------------------------
  // Legal responses
  // ---------------------------------------------------------------------------
  a_b_no_exokay: assert property (@(posedge aclk) disable iff (!aresetn)
      bvalid |-> (bresp != EXOKAY)) else $error("AXI-L: EXOKAY on BRESP");
  a_r_no_exokay: assert property (@(posedge aclk) disable iff (!aresetn)
      rvalid |-> (rresp != EXOKAY)) else $error("AXI-L: EXOKAY on RRESP");

  // ---------------------------------------------------------------------------
  // Reset: all VALIDs low while ARESETn asserted (sampled on the clock)
  // ---------------------------------------------------------------------------
  always @(posedge aclk) begin
    if (!aresetn) begin
      a_rst_valids: assert (!awvalid && !wvalid && !arvalid && !bvalid && !rvalid)
        else $error("AXI-L: VALID asserted during reset");
    end
  end

  // ---------------------------------------------------------------------------
  // X/Z checks
  // ---------------------------------------------------------------------------
  always @(posedge aclk) begin
    if (aresetn) begin
      a_ctrl_known: assert (!$isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
                                          arvalid, arready, rvalid, rready}))
        else $error("AXI-L: X/Z on a VALID/READY signal");
      if (awvalid) a_aw_known: assert (!$isunknown({awaddr, awprot})) else $error("AXI-L: X/Z on AW payload");
      if (wvalid)  a_w_known:  assert (!$isunknown({wdata, wstrb}))   else $error("AXI-L: X/Z on W payload");
      if (bvalid)  a_b_known:  assert (!$isunknown(bresp))            else $error("AXI-L: X/Z on BRESP");
      if (arvalid) a_ar_known: assert (!$isunknown({araddr, arprot})) else $error("AXI-L: X/Z on AR payload");
      if (rvalid)  a_r_known:  assert (!$isunknown({rdata, rresp}))   else $error("AXI-L: X/Z on R payload");
    end
  end

  // ---------------------------------------------------------------------------
  // Transaction ordering: count handshakes. A write response may only be
  // given for a write whose AW and W have both been accepted; a read response
  // only for an accepted AR.
  // ---------------------------------------------------------------------------
  int unsigned aw_cnt, w_cnt, b_cnt, ar_cnt, r_cnt;
  int unsigned b_wait, r_wait;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_cnt <= 0; w_cnt <= 0; b_cnt <= 0; ar_cnt <= 0; r_cnt <= 0;
      b_wait <= 0; r_wait <= 0;
    end else begin
      if (bvalid) begin
        a_b_after_aw_w: assert ((aw_cnt > b_cnt) && (w_cnt > b_cnt))
          else $error("AXI-L: BVALID without a completed AW+W (aw=%0d w=%0d b=%0d)", aw_cnt, w_cnt, b_cnt);
      end
      if (rvalid) begin
        a_r_after_ar: assert (ar_cnt > r_cnt)
          else $error("AXI-L: RVALID without an accepted AR (ar=%0d r=%0d)", ar_cnt, r_cnt);
      end
      if (awvalid && awready) aw_cnt <= aw_cnt + 1;
      if (wvalid  && wready)  w_cnt  <= w_cnt  + 1;
      if (bvalid  && bready)  b_cnt  <= b_cnt  + 1;
      if (arvalid && arready) ar_cnt <= ar_cnt + 1;
      if (rvalid  && rready)  r_cnt  <= r_cnt  + 1;

      // Response latency watchdog: writes/reads accepted but not answered.
      if ((aw_cnt > b_cnt) && (w_cnt > b_cnt) && !bvalid) b_wait <= b_wait + 1; else b_wait <= 0;
      if ((ar_cnt > r_cnt) && !rvalid)                    r_wait <= r_wait + 1; else r_wait <= 0;
      if (MAX_WAIT != 0) begin
        a_b_latency: assert (b_wait < MAX_WAIT) else $error("AXI-L: no BVALID within %0d cycles", MAX_WAIT);
        a_r_latency: assert (r_wait < MAX_WAIT) else $error("AXI-L: no RVALID within %0d cycles", MAX_WAIT);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Protocol coverage
  // ---------------------------------------------------------------------------
  c_aw_before_w:   cover property (@(posedge aclk) disable iff (!aresetn) (awvalid && awready && !wvalid));
  c_w_before_aw:   cover property (@(posedge aclk) disable iff (!aresetn) (wvalid && wready && !awvalid));
  c_aw_w_same:     cover property (@(posedge aclk) disable iff (!aresetn) (awvalid && awready && wvalid && wready));
  c_aw_wait:       cover property (@(posedge aclk) disable iff (!aresetn) (awvalid && !awready));
  c_b_backpress:   cover property (@(posedge aclk) disable iff (!aresetn) (bvalid && !bready));
  c_r_backpress:   cover property (@(posedge aclk) disable iff (!aresetn) (rvalid && !rready));
  c_b_slverr:      cover property (@(posedge aclk) disable iff (!aresetn) (bvalid && bready && bresp == 2'b10));
  c_b_decerr:      cover property (@(posedge aclk) disable iff (!aresetn) (bvalid && bready && bresp == 2'b11));
  c_r_slverr:      cover property (@(posedge aclk) disable iff (!aresetn) (rvalid && rready && rresp == 2'b10));
  c_r_decerr:      cover property (@(posedge aclk) disable iff (!aresetn) (rvalid && rready && rresp == 2'b11));
  c_rd_wr_overlap: cover property (@(posedge aclk) disable iff (!aresetn) (arvalid && awvalid));

endmodule
