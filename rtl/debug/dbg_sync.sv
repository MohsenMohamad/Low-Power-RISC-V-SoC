// 2-flop synchroniser (per-bit). Thin technology wrapper with a generic
// simulation model; replaced by the SoC-wide synchroniser cell at merge.
// Only single-bit signals, Gray-coded buses or quasi-static buses may be
// passed through it.
module dbg_sync #(
  parameter int unsigned WIDTH = 1,
  parameter logic [WIDTH-1:0] RESET_VAL = '0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] q_o
);
  logic [WIDTH-1:0] meta_q, sync_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_q <= RESET_VAL;
      sync_q <= RESET_VAL;
    end else begin
      meta_q <= d_i;
      sync_q <= meta_q;
    end
  end
  assign q_o = sync_q;
endmodule
