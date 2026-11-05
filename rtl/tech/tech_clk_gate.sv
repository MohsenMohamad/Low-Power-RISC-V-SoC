// -----------------------------------------------------------------------------
// tech_clk_gate - integrated clock gate (ICG) wrapper
//
// Generic model of a latch-based, positive-edge ICG: the enable is captured by a
// latch that is transparent while clk_i is low, so clk_o can only start or stop
// on a full high phase (no glitches). Replace the body with the library ICG cell
// (ASIC) or BUFGCE (FPGA) when targeting a technology.
// en_i must be synchronous to clk_i.
// -----------------------------------------------------------------------------
module tech_clk_gate (
  input  logic clk_i,
  input  logic en_i,
  input  logic test_en_i,
  output logic clk_o
);
  logic en_latched;
  /* verilator lint_off LATCH */
  always_latch begin
    if (!clk_i) en_latched = en_i | test_en_i;
  end
  /* verilator lint_on LATCH */
  assign clk_o = clk_i & en_latched;
endmodule
