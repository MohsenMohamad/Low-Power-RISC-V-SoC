// -----------------------------------------------------------------------------
// cdc_async_fifo - dual-clock FIFO with gray-coded pointers
//
// Classic two-synchronizer async FIFO. DEPTH must be a power of two. Pointers
// carry one extra wrap bit; their gray encodings are passed through tech_sync
// (only one bit changes per increment, so per-bit synchronization is safe).
// Status outputs:
//   w_empty_o : writer-side view "FIFO empty" (conservative: may stay low for a
//               few clocks after the reader drained it). Used for idle checks.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module cdc_async_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 4
) (
  // write side
  input  logic             wclk_i,
  input  logic             wrst_ni,
  input  logic             wvalid_i,
  output logic             wready_o,
  input  logic [WIDTH-1:0] wdata_i,
  output logic             w_empty_o,
  // read side
  input  logic             rclk_i,
  input  logic             rrst_ni,
  output logic             rvalid_o,
  input  logic             rready_i,
  output logic [WIDTH-1:0] rdata_o
);
  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];

  logic [AW:0] wbin_q, wgray_q, rgray_wsync;
  logic [AW:0] rbin_q, rgray_q, wgray_rsync;

  function automatic [AW:0] bin2gray(input [AW:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  // ---------------- write domain ----------------
  logic        wfull;
  logic        wpush;
  logic [AW:0] wbin_nxt;

  assign wfull    = (wgray_q == {~rgray_wsync[AW:AW-1], rgray_wsync[AW-2:0]});
  assign wready_o = !wfull;
  assign wpush    = wvalid_i && !wfull;
  assign wbin_nxt = wbin_q + (AW+1)'(wpush);

  always_ff @(posedge wclk_i or negedge wrst_ni) begin
    if (!wrst_ni) begin
      wbin_q  <= '0;
      wgray_q <= '0;
    end else begin
      wbin_q  <= wbin_nxt;
      wgray_q <= bin2gray(wbin_nxt);
    end
  end

  always_ff @(posedge wclk_i) begin
    if (wpush) mem[wbin_q[AW-1:0]] <= wdata_i;
  end

  tech_sync #(.WIDTH(AW+1), .STAGES(2)) u_sync_r2w (
    .clk_i (wclk_i), .rst_ni (wrst_ni), .d_i (rgray_q), .q_o (rgray_wsync)
  );

  assign w_empty_o = (wgray_q == rgray_wsync);

  // ---------------- read domain ----------------
  logic        rempty;
  logic        rpop;
  logic [AW:0] rbin_nxt;

  assign rempty   = (rgray_q == wgray_rsync);
  assign rvalid_o = !rempty;
  assign rpop     = rready_i && !rempty;
  assign rbin_nxt = rbin_q + (AW+1)'(rpop);
  assign rdata_o  = mem[rbin_q[AW-1:0]];

  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      rbin_q  <= '0;
      rgray_q <= '0;
    end else begin
      rbin_q  <= rbin_nxt;
      rgray_q <= bin2gray(rbin_nxt);
    end
  end

  tech_sync #(.WIDTH(AW+1), .STAGES(2)) u_sync_w2r (
    .clk_i (rclk_i), .rst_ni (rrst_ni), .d_i (wgray_q), .q_o (wgray_rsync)
  );

  // ---------------- assertions ----------------
  // Gray pointers change by at most one bit per clock of their own domain.
  `SVA_ASSERT_NXT(a_wgray_onebit, wclk_i, wrst_ni, 1'b1,
                  $countones(wgray_q ^ $past(wgray_q)) <= 1)
  `SVA_ASSERT_NXT(a_rgray_onebit, rclk_i, rrst_ni, 1'b1,
                  $countones(rgray_q ^ $past(rgray_q)) <= 1)
  `SVA_COVER(c_full,  wclk_i, wrst_ni, wfull)
  `SVA_COVER(c_pop, rclk_i, rrst_ni, rpop)
endmodule
