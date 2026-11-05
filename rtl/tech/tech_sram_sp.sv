// Single-port synchronous SRAM wrapper.
//
// Thin technology wrapper: this file is the generic simulation/FPGA-inferable
// model. ASIC flows replace the body with a compiled RAM macro instance.
//
// Behaviour (must be preserved by any replacement):
//   * en=1, we=0 : rdata <= mem[addr] on the rising edge (1-cycle read latency)
//   * en=1, we=1 : mem[addr] <= (wdata & bitmask) | (mem[addr] & ~bitmask);
//                  rdata is left unchanged
//   * en=0       : rdata holds its previous value (macro output latch)
//   * contents are undefined after power-up (no reset)
module tech_sram_sp #(
  parameter int DEPTH = 128,
  parameter int WIDTH = 32,
  localparam int AW = $clog2(DEPTH)
) (
  input  logic             clk,
  input  logic             en,
  input  logic             we,
  input  logic [AW-1:0]    addr,
  input  logic [WIDTH-1:0] wdata,
  input  logic [WIDTH-1:0] wmask,   // bit-level write mask
  output logic [WIDTH-1:0] rdata
);

  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (en) begin
      if (we) mem[addr] <= (wdata & wmask) | (mem[addr] & ~wmask);
      else    rdata     <= mem[addr];
    end
  end

endmodule
