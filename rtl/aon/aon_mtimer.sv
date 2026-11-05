// -----------------------------------------------------------------------------
// aon_mtimer - RISC-V machine timer (mtime / mtimecmp) and software interrupt
//
//   0x00 MTIME_LO   RW     0x04 MTIME_HI   RW
//   0x08 MTIMECMP_LO RW    0x0C MTIMECMP_HI RW
//   0x10 MSIP       RW [0]
// mtime increments once per clk_aon cycle and keeps running in every CPU power
// state. mtip = (mtime >= mtimecmp). Both mtip and msip are PMU wake events.
// -----------------------------------------------------------------------------
module aon_mtimer (
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic        mtip_o,
  output logic        msip_o,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [11:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic [3:0]  wstrb_i,
  output logic        ack_o,
  output logic [31:0] rdata_o,
  output logic        err_o
);
  logic [63:0] mtime_q, mtimecmp_q;
  logic        msip_q;
  logic        wr;

  assign wr     = req_i && we_i && (wstrb_i == 4'hF);
  assign ack_o  = req_i;
  assign mtip_o = (mtime_q >= mtimecmp_q);
  assign msip_o = msip_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q    <= '0;
      mtimecmp_q <= '1;
      msip_q     <= 1'b0;
    end else begin
      mtime_q <= mtime_q + 64'd1;
      if (wr) begin
        case (addr_i[11:2])
          10'h0: mtime_q[31:0]     <= wdata_i;
          10'h1: mtime_q[63:32]    <= wdata_i;
          10'h2: mtimecmp_q[31:0]  <= wdata_i;
          10'h3: mtimecmp_q[63:32] <= wdata_i;
          10'h4: msip_q            <= wdata_i[0];
          default: ;
        endcase
      end
    end
  end

  logic unused;
  assign unused = ^addr_i[1:0];

  always_comb begin
    rdata_o = '0;
    err_o   = we_i && (wstrb_i != 4'hF);
    case (addr_i[11:2])
      10'h0: rdata_o = mtime_q[31:0];
      10'h1: rdata_o = mtime_q[63:32];
      10'h2: rdata_o = mtimecmp_q[31:0];
      10'h3: rdata_o = mtimecmp_q[63:32];
      10'h4: rdata_o = {31'b0, msip_q};
      default: err_o = 1'b1;
    endcase
  end
endmodule
