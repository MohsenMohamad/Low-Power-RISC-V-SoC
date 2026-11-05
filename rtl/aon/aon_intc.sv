// -----------------------------------------------------------------------------
// aon_intc - always-on interrupt controller
//
// Level-sensitive sources; each source block owns its own status/clear bits.
//   0x00 PENDING  RO  raw source levels
//   0x04 ENABLE   RW  per-source enable
//   0x08 ACTIVE   RO  PENDING & ENABLE
// irq_o (machine external interrupt, meip) = |ACTIVE. It is also a PMU wake
// event, so it must live in PD_AON.
// -----------------------------------------------------------------------------
module aon_intc #(
  parameter int N = 8
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [N-1:0] src_i,
  output logic         irq_o,
  input  logic         req_i,
  input  logic         we_i,
  input  logic [11:0]  addr_i,
  input  logic [31:0]  wdata_i,
  input  logic [3:0]   wstrb_i,
  output logic         ack_o,
  output logic [31:0]  rdata_o,
  output logic         err_o
);
  logic [N-1:0] en_q;
  logic [N-1:0] active;

  assign active = src_i & en_q;
  assign irq_o  = |active;
  assign ack_o  = req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) en_q <= '0;
    else if (req_i && we_i && addr_i[11:2] == 10'h1 && wstrb_i[0]) en_q <= wdata_i[N-1:0];
  end

  logic unused;
  assign unused = ^{addr_i[1:0], wdata_i[31:N], wstrb_i[3:1]};

  always_comb begin
    rdata_o = '0;
    err_o   = 1'b0;
    case (addr_i[11:2])
      10'h0: begin rdata_o[N-1:0] = src_i;  err_o = we_i; end
      10'h1:       rdata_o[N-1:0] = en_q;
      10'h2: begin rdata_o[N-1:0] = active; err_o = we_i; end
      default: err_o = 1'b1;
    endcase
  end
endmodule
