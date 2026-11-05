// Two-clock simple dual-port RAM (write port in clk_w, read port in clk_r,
// synchronous read). Thin technology wrapper with a generic model; replaced
// by a RAM macro / FPGA block RAM at merge. No reset (macro behaviour).
module dbg_ram_2c #(
  parameter int unsigned DEPTH = 64,
  parameter int unsigned WIDTH = 128,
  localparam int unsigned AW = $clog2(DEPTH)
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
