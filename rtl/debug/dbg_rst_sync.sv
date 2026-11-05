// Reset synchroniser: asynchronous assertion, synchronous de-assertion.
module dbg_rst_sync (
  input  logic clk_i,
  input  logic rst_ni,
  output logic rst_no
);
  logic [1:0] q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) q <= 2'b00;
    else         q <= {q[0], 1'b1};
  end
  assign rst_no = q[1];
endmodule
