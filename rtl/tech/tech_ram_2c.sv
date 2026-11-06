// Two-clock simple dual-port RAM wrapper (write port on clk_w, read port on
// clk_r, synchronous read).
//
// Thin technology wrapper: this file is the generic simulation/FPGA-inferable
// model. ASIC flows replace the body with a two-port RAM macro instance.
//
// Behaviour (must be preserved by any replacement):
//   * we_i=1 : mem[waddr_i] <= wdata_i on the rising edge of clk_w_i
//   * re_i=1 : rdata_o <= mem[raddr_i] on the rising edge of clk_r_i
//   * re_i=0 : rdata_o holds its previous value
//   * contents are undefined after power-up (no reset); a read of the word
//     being written in the same instant returns undefined data
module tech_ram_2c #(
  parameter int DEPTH = 64,
  parameter int WIDTH = 128,
  localparam int AW = $clog2(DEPTH)
) (
  input  logic             clk_w_i,
  input  logic             we_i,
  input  logic [AW-1:0]    waddr_i,
  input  logic [WIDTH-1:0] wdata_i,
  input  logic             clk_r_i,
  input  logic             re_i,
  input  logic [AW-1:0]    raddr_i,
  output logic [WIDTH-1:0] rdata_o
);
  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk_w_i) begin
    if (we_i) mem[waddr_i] <= wdata_i;
  end

  always_ff @(posedge clk_r_i) begin
    if (re_i) rdata_o <= mem[raddr_i];
  end
endmodule
