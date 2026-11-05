// 31 x 32-bit register file, two asynchronous read ports, one write port.
// Reads of the register being written in the same cycle return the new value
// (write-through), which removes the WB->ID hazard.
module core_regfile (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [4:0]  raddr_a,
  output logic [31:0] rdata_a,
  input  logic [4:0]  raddr_b,
  output logic [31:0] rdata_b,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata
);

  logic [31:0] regs [1:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 1; i < 32; i++) regs[i] <= '0;
    end else if (we && waddr != 5'd0) begin
      regs[waddr] <= wdata;
    end
  end

  always_comb begin
    if (raddr_a == 5'd0)                rdata_a = '0;
    else if (we && waddr == raddr_a)    rdata_a = wdata;
    else                                rdata_a = regs[raddr_a];
    if (raddr_b == 5'd0)                rdata_b = '0;
    else if (we && waddr == raddr_b)    rdata_b = wdata;
    else                                rdata_b = regs[raddr_b];
  end

endmodule
