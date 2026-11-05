// -----------------------------------------------------------------------------
// tech_rom - read-only memory macro wrapper
//
// 32-bit words, 1-cycle synchronous read, contents loaded from INIT_FILE
// (hex, one word per line). Replace with the ROM macro (ASIC) or an
// initialised block RAM (FPGA).
// -----------------------------------------------------------------------------
module tech_rom #(
  parameter int    WORDS     = 4096,
  parameter int    AW        = $clog2(WORDS),
  parameter string INIT_FILE = ""
) (
  input  logic          clk_i,
  input  logic          cs_i,
  input  logic [AW-1:0] addr_i,
  output logic [31:0]   rdata_o
);
  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;  // nop fill
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk_i) begin
    if (cs_i) rdata_o <= mem[addr_i];
  end
endmodule
