// -----------------------------------------------------------------------------
// cdc_snapshot_src (+ cdc_snapshot_dst.sv) - coherent multi-bit value crossing
//
// Toggle request/acknowledge handshake that moves a coherent copy of a
// multi-bit value (here: the 64-bit mtime) from a source clock domain (PD_AON,
// clk_aon) to a destination clock domain (PD_CPU, clk_cpu). The data bus never
// passes through a synchronizer: it is captured into snap_q in the source
// domain and is stable for at least two destination clock cycles (the
// acknowledge synchronizer depth) before the destination samples it.
//
//   dst: req_tgl ^= 1 ------------------> [2-flop sync] --> src
//   src: on req_s != ack_q: snap_q <= value; ack_q <= req_s
//   src: ack_q -------------------------> [2-flop sync] --> dst
//   dst: on ack_s == req_tgl: value_q <= snap_q (stable); next request
//
// The destination re-arms immediately, so value_o is refreshed every ~2+2
// source/destination cycles: it lags the live counter by a few clk_aon cycles,
// never shows a torn (partially updated) value, and is monotonic for a
// monotonic source.
//
// Power gating: the destination lives in the switchable domain. Its request
// output is isolated (clamped 0) in PD_AON while PD_CPU is off. After
// power-up, the first handshake only primes the protocol (valid_o stays 0)
// so a snapshot taken before the power cycle is never used.
// -----------------------------------------------------------------------------
module cdc_snapshot_src #(
  parameter int W = 64
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [W-1:0] value_i,
  input  logic         req_tgl_i,   // asynchronous (destination domain, isolated)
  output logic         ack_tgl_o,   // to destination (synchronized there)
  output logic [W-1:0] snap_o       // to destination (quasi-static)
);
  logic req_s, ack_q;
  logic [W-1:0] snap_q;

  tech_sync #(.WIDTH(1), .STAGES(2)) u_req_sync (
    .clk_i, .rst_ni, .d_i (req_tgl_i), .q_o (req_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ack_q  <= 1'b0;
      snap_q <= '0;
    end else if (req_s != ack_q) begin
      snap_q <= value_i;
      ack_q  <= req_s;
    end
  end

  assign ack_tgl_o = ack_q;
  assign snap_o    = snap_q;
endmodule
