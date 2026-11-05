// -----------------------------------------------------------------------------
// tech_clk_or - clock combiner wrapper (N-input clock OR)
//
// Used as the final stage of the glitch-free clock multiplexer: the inputs are
// mutually exclusive gated clocks, so an OR forms the multiplexed clock.
// Replace with a library clock OR / clock mux tree (ASIC) or BUFGMUX (FPGA).
// -----------------------------------------------------------------------------
module tech_clk_or #(
  parameter int N = 2
) (
  input  logic [N-1:0] clk_i,
  output logic         clk_o
);
  assign clk_o = |clk_i;
endmodule
