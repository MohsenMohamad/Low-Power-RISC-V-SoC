// -----------------------------------------------------------------------------
// cdc_snapshot_formal - SymbiYosys harness for the mtime snapshot crossing
// (rtl/common/cdc_snapshot_src.sv / cdc_snapshot_dst.sv), multiclock.
//
// Source and destination clocks are free inputs (arbitrary unrelated
// frequencies). The source value is a monotonic counter that advances by an
// arbitrary step (0..3) per source clock, which also models software writes
// that move it forward. The destination reset is a free input after the
// initial reset (power cycles of PD_CPU at any time), with the interface
// requirement of cdc_snapshot_src.sv: once asserted it lasts at least
// RST_MIN_SRC_EDGES source clock edges (the source then sees the request low
// long enough to close any open handshake). The SoC meets it: the PD_CPU
// reset spans isolation, switch-off and switch-on (checked in sim/tb_soc.sv).
//
// Proven:
//   a_no_tear   a value captured by the destination equals the source
//               snapshot register, which was stable for at least two global
//               time steps before the capture (no sampling of a changing bus)
//   a_not_ahead the destination value never exceeds the live source value
//   a_monotonic without an intervening destination reset the destination value
//               never decreases
// Covered: repeated updates, and a fresh value after a destination reset.
// -----------------------------------------------------------------------------
module cdc_snapshot_formal (
  input logic       sclk_i,
  input logic       dclk_i,
  input logic       srst_ni,
  input logic       drst_ni,
  input logic [1:0] inc_i
);
  localparam int W = 8;

  logic [W-1:0] cnt = '0;
  logic [W-1:0] snap, value;
  logic         req, ack, valid;

  cdc_snapshot_src #(.W(W)) u_src (
    .clk_i (sclk_i), .rst_ni (srst_ni), .value_i (cnt),
    .req_i (req), .ack_o (ack), .snap_o (snap)
  );
  cdc_snapshot_dst #(.W(W)) u_dst (
    .clk_i (dclk_i), .rst_ni (drst_ni), .snap_i (snap), .ack_i (ack),
    .req_o (req), .value_o (value), .valid_o (valid)
  );

  // monotonic source; stays below the wrap point so ">=" is meaningful
  always @(posedge sclk_i) if (srst_ni && cnt < 8'd240) cnt <= cnt + W'(inc_i);

  localparam int RST_MIN_SRC_EDGES = 6;
  logic [2:0] rst_src_edges = '0;   // source clock edges seen during the destination reset
  always @(posedge sclk_i)
    if (drst_ni) rst_src_edges <= '0;
    else if (rst_src_edges != 3'd7) rst_src_edges <= rst_src_edges + 3'd1;

  logic init = 1'b1;
  always @($global_clock) begin
    init <= 1'b0;
    if (init) assume (!srst_ni && !drst_ni);
    else begin
      if ($past(srst_ni)) assume (srst_ni);   // source (PD_AON) reset only at power-on
      if (srst_ni && $past(srst_ni) && drst_ni && !$past(drst_ni))
        assume (rst_src_edges >= 3'(RST_MIN_SRC_EDGES));
    end
  end

  always @($global_clock) if (!init && srst_ni) begin
    if (drst_ni && $past(drst_ni) && valid && value != $past(value))
      a_no_tear: assert (value == $past(snap) && $past(snap) == $past(snap, 2));
    if (valid) a_not_ahead: assert (value <= cnt);
    if (drst_ni && $past(drst_ni) && valid && $past(valid))
      a_monotonic: assert (value >= $past(value));
    c_two_updates: cover (valid && value >= 8'd3 && value != $past(value) && $past(value) != 0);
    c_after_reset: cover (valid && $fell($past(drst_ni)) == 1'b0 && value > 8'd5 && drst_ni);
  end
endmodule
