// Transfers a counter that changes by at most +1 per source clock (or is
// reset while the destination ignores it) from clk_src to clk_dst:
// binary -> Gray register (source) -> 2-flop synchroniser -> binary (dest).
module dbg_gray_sync #(
  parameter int unsigned WIDTH = 32
) (
  input  logic             clk_src_i,
  input  logic             rst_src_ni,
  input  logic [WIDTH-1:0] bin_i,
  input  logic             clk_dst_i,
  input  logic             rst_dst_ni,
  output logic [WIDTH-1:0] bin_o
);
  logic [WIDTH-1:0] gray_q, gray_dst;
  always_ff @(posedge clk_src_i or negedge rst_src_ni) begin
    if (!rst_src_ni) gray_q <= '0;
    else             gray_q <= bin_i ^ (bin_i >> 1);
  end
  tech_sync #(.WIDTH(WIDTH)) u_sync (
    .clk_i(clk_dst_i), .rst_ni(rst_dst_ni), .d_i(gray_q), .q_o(gray_dst)
  );
  always_comb begin
    bin_o[WIDTH-1] = gray_dst[WIDTH-1];
    for (int i = WIDTH - 2; i >= 0; i--) bin_o[i] = bin_o[i+1] ^ gray_dst[i];
  end
endmodule
