// -----------------------------------------------------------------------------
// axil_reg_slave - AXI4-Lite slave to simple register-request adapter
//
// Register-side protocol (all synchronous to clk_i):
//   req_o is held high with we_o/addr_o/wdata_o/wstrb_o stable until the
//   peripheral answers with a one-cycle ack_i (which may be in the same cycle
//   as req_o for zero-wait registers). rdata_i/err_i are sampled with ack_i.
// One transaction at a time; a write needs both AW and W before it is issued.
// -----------------------------------------------------------------------------
module axil_reg_slave #(
  parameter int AW = 12   // number of address bits passed to the peripheral
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          s_awvalid_i,
  output logic          s_awready_o,
  input  logic [31:0]   s_awaddr_i,
  input  logic          s_wvalid_i,
  output logic          s_wready_o,
  input  logic [31:0]   s_wdata_i,
  input  logic [3:0]    s_wstrb_i,
  output logic          s_bvalid_o,
  input  logic          s_bready_i,
  output logic [1:0]    s_bresp_o,
  input  logic          s_arvalid_i,
  output logic          s_arready_o,
  input  logic [31:0]   s_araddr_i,
  output logic          s_rvalid_o,
  input  logic          s_rready_i,
  output logic [31:0]   s_rdata_o,
  output logic [1:0]    s_rresp_o,
  // register request interface
  output logic          req_o,
  output logic          we_o,
  output logic [AW-1:0] addr_o,
  output logic [31:0]   wdata_o,
  output logic [3:0]    wstrb_o,
  input  logic          ack_i,
  input  logic [31:0]   rdata_i,
  input  logic          err_i
);
  logic unused;
  assign unused = ^{s_awaddr_i[31:AW], s_araddr_i[31:AW]};

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_BRESP, S_RRESP} state_e;
  state_e state_q;

  logic [31:0] rdata_q;
  logic        err_q;

  assign s_awready_o = (state_q == S_IDLE) && s_awvalid_i && s_wvalid_i;
  assign s_wready_o  = (state_q == S_IDLE) && s_awvalid_i && s_wvalid_i;
  assign s_arready_o = (state_q == S_IDLE) && !(s_awvalid_i && s_wvalid_i);

  assign req_o      = (state_q == S_REQ);
  assign s_bvalid_o = (state_q == S_BRESP);
  assign s_bresp_o  = err_q ? 2'b10 : 2'b00;
  assign s_rvalid_o = (state_q == S_RRESP);
  assign s_rdata_o  = rdata_q;
  assign s_rresp_o  = err_q ? 2'b10 : 2'b00;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      we_o    <= 1'b0;
      addr_o  <= '0;
      wdata_o <= '0;
      wstrb_o <= '0;
      rdata_q <= '0;
      err_q   <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (s_awvalid_i && s_wvalid_i) begin
            we_o    <= 1'b1;
            addr_o  <= s_awaddr_i[AW-1:0];
            wdata_o <= s_wdata_i;
            wstrb_o <= s_wstrb_i;
            state_q <= S_REQ;
          end else if (s_arvalid_i) begin
            we_o    <= 1'b0;
            addr_o  <= s_araddr_i[AW-1:0];
            wstrb_o <= '0;
            state_q <= S_REQ;
          end
        end
        S_REQ: begin
          if (ack_i) begin
            rdata_q <= rdata_i;
            err_q   <= err_i;
            state_q <= we_o ? S_BRESP : S_RRESP;
          end
        end
        S_BRESP: if (s_bready_i) state_q <= S_IDLE;
        S_RRESP: if (s_rready_i) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
