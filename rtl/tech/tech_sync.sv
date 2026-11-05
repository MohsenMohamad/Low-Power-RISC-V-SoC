// -----------------------------------------------------------------------------
// tech_sync - multi-flop synchronizer wrapper (per-bit, asynchronous reset)
//
// WIDTH independent synchronizer chains of STAGES flops each. Multi-bit buses
// may only be passed through this cell when at most one bit changes per
// destination clock (gray-coded pointers, one-hot status, quasi-static levels).
// Replace with the library synchronizer cell for ASIC (MTBF-characterised).
// -----------------------------------------------------------------------------
module tech_sync #(
  parameter int              WIDTH     = 1,
  parameter int              STAGES    = 2,
  parameter logic [WIDTH-1:0] RESET_VAL = '0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] q_o
);
  logic [WIDTH-1:0] stage_q [STAGES];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int s = 0; s < STAGES; s++) stage_q[s] <= RESET_VAL;
    end else begin
      stage_q[0] <= d_i;
      for (int s = 1; s < STAGES; s++) stage_q[s] <= stage_q[s-1];
    end
  end

  assign q_o = stage_q[STAGES-1];
endmodule
