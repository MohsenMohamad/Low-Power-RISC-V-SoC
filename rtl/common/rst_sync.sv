// -----------------------------------------------------------------------------
// rst_sync - reset synchronizer (asynchronous assert, synchronous de-assert)
// -----------------------------------------------------------------------------
module rst_sync #(
  parameter int STAGES = 2
) (
  input  logic clk_i,
  input  logic arst_ni,  // asynchronous reset request (active low)
  output logic rst_no    // reset synchronous to clk_i (active low)
);
  tech_sync #(.WIDTH(1), .STAGES(STAGES), .RESET_VAL(1'b0)) u_sync (
    .clk_i  (clk_i),
    .rst_ni (arst_ni),
    .d_i    (1'b1),
    .q_o    (rst_no)
  );
endmodule
