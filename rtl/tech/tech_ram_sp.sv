// -----------------------------------------------------------------------------
// tech_ram_sp - single-port RAM macro wrapper with retention mode
//
// 32-bit words, byte enables, 1-cycle synchronous read.
//   ret_i : retention (deep-sleep) mode. The array keeps its contents, the
//           periphery is powered down: accesses are not allowed and the read
//           port output is undefined. The simulation model drives X on rdata
//           while in retention (OFF-state corruption of the periphery) and the
//           assertion below flags any access attempt.
// Replace with the compiled SRAM macro (ASIC) or block RAM (FPGA).
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module tech_ram_sp #(
  parameter int    WORDS     = 1024,
  parameter int    AW        = $clog2(WORDS),
  parameter string INIT_FILE = ""
) (
  input  logic          clk_i,
  input  logic          rst_ni,     // used by assertions only
  input  logic          ret_i,
  input  logic          cs_i,
  input  logic          we_i,
  input  logic [3:0]    be_i,
  input  logic [AW-1:0] addr_i,
  input  logic [31:0]   wdata_i,
  output logic [31:0]   rdata_o
);
  logic [31:0] mem [WORDS];
  logic [31:0] rdata_q;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk_i) begin
    if (cs_i && !ret_i) begin
      if (we_i) begin
        for (int b = 0; b < 4; b++)
          if (be_i[b]) mem[addr_i][8*b +: 8] <= wdata_i[8*b +: 8];
      end
      rdata_q <= mem[addr_i];
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Retention corruption model: periphery is off, the read port is undefined.
  assign rdata_o = ret_i ? 32'hxxxx_xxxx : rdata_q;
`else
  assign rdata_o = rdata_q;
`endif
`else
  assign rdata_o = rdata_q;
`endif

`ifndef SVA_ON
`ifndef FORMAL
  logic unused;
  assign unused = rst_ni;
`endif
`endif
  `SVA_ASSERT(a_no_access_in_retention, clk_i, rst_ni, !(ret_i && cs_i))
endmodule
