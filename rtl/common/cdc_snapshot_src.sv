// -----------------------------------------------------------------------------
// cdc_snapshot_src (+ cdc_snapshot_dst.sv) - coherent multi-bit value crossing
//
// Four-phase request/acknowledge handshake that moves a coherent copy of a
// multi-bit value (here: the 64-bit mtime) from a source clock domain (PD_AON,
// clk_aon) to a destination clock domain (PD_CPU, clk_cpu). The data bus never
// passes through a synchronizer: it is captured into snap_q in the source
// domain when the acknowledge rises and cannot change again before the
// destination has sampled it and withdrawn its request.
//
//   dst: req 0->1 (only when it sees ack = 0) --[2-flop sync]--> src
//   src: req_s = 1, ack = 0 : snap_q <= value; ack <= 1
//   src: ack -----------------------------------[2-flop sync]--> dst
//   dst: ack_s = 1 : value_q <= snap_q (stable since ack rose); req <= 0
//   src: req_s = 0, ack = 1 : ack <= 0
//
// value_o is refreshed every ~4 source + ~4 destination cycles; it lags the
// live counter by a few clk_aon cycles, never shows a torn value, and is
// monotonic for a monotonic source.
//
// Power gating / reset: the destination lives in the switchable domain and may
// be reset in the middle of a handshake. Interface requirement: a destination
// reset, once asserted, lasts at least 6 source clock edges (its request is
// low throughout), so the source closes any open handshake (ack low) before
// the destination restarts. After its reset the destination waits until its
// acknowledge synchronizer holds real samples (SETTLE cycles) and the
// acknowledge is low before it raises a new request. Formal (SymbiYosys,
// formal/cdc_snapshot.sby) found that without this minimum reset length a
// stale acknowledge can be taken as the answer to a new request while the
// source updates the snapshot (torn capture); with it, the proof shows no
// torn capture, never ahead of the source, monotonic between destination
// resets. In the SoC the PD_CPU reset spans isolation (request clamped 0),
// switch-off and switch-on, many clk_aon cycles; sim/tb_soc.sv asserts it.
// -----------------------------------------------------------------------------
module cdc_snapshot_src #(
  parameter int W = 64
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [W-1:0] value_i,
  input  logic         req_i,       // asynchronous (destination domain, isolated)
  output logic         ack_o,       // to destination (synchronized there)
  output logic [W-1:0] snap_o       // to destination (stable while ack_o is high)
);
  logic req_s, ack_q;
  logic [W-1:0] snap_q;

  tech_sync #(.WIDTH(1), .STAGES(2)) u_req_sync (
    .clk_i, .rst_ni, .d_i (req_i), .q_o (req_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ack_q  <= 1'b0;
      snap_q <= '0;
    end else if (req_s && !ack_q) begin
      snap_q <= value_i;
      ack_q  <= 1'b1;
    end else if (!req_s && ack_q) begin
      ack_q  <= 1'b0;
    end
  end

  assign ack_o  = ack_q;
  assign snap_o = snap_q;
endmodule
