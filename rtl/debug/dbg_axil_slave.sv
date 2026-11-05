// AXI4-Lite slave front end shared by the debug blocks.
//
// One outstanding write and one outstanding read. When idle, AWREADY,
// WREADY and ARREADY are high, so a request presented in cycle t is
// accepted in t and answered (BVALID / RVALID) in t+1. Address and data
// channels of a write may arrive in any order; each is held until the other
// one arrives.
//
// Register-side interface (all clk_i):
//   reg_we_o    one-cycle write strobe, reg_waddr_o / reg_wdata_o valid
//   reg_werr_i  combinational, same cycle as reg_we_o: SLVERR for this write
//   reg_re_o    one-cycle read strobe, reg_raddr_o valid in this cycle and
//               held (reg_raddr_q_o) in the next one
//   reg_rdata_i / reg_rerr_i  sampled in the cycle after reg_re_o
// Writes with WSTRB != 4'hF get SLVERR and no reg_we_o.
module dbg_axil_slave #(
  parameter int unsigned ADDR_W = 12
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  // AXI4-Lite
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic [2:0]        s_axil_awprot,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic [2:0]        s_axil_arprot,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // register interface
  output logic              reg_we_o,
  output logic [ADDR_W-1:0] reg_waddr_o,
  output logic [31:0]       reg_wdata_o,
  input  logic              reg_werr_i,
  output logic              reg_re_o,
  output logic [ADDR_W-1:0] reg_raddr_o,
  output logic [ADDR_W-1:0] reg_raddr_q_o,
  input  logic [31:0]       reg_rdata_i,
  input  logic              reg_rerr_i
);
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

  // ---------------- write ----------------
  logic              aw_full, w_full;
  logic [ADDR_W-1:0] aw_q;
  logic [31:0]       w_q;
  logic [3:0]        ws_q;

  assign s_axil_awready = !aw_full && !s_axil_bvalid;
  assign s_axil_wready  = !w_full  && !s_axil_bvalid;

  wire aw_hs = s_axil_awvalid && s_axil_awready;
  wire w_hs  = s_axil_wvalid  && s_axil_wready;
  wire have_aw = aw_hs || aw_full;
  wire have_w  = w_hs  || w_full;
  wire do_wr   = have_aw && have_w && !s_axil_bvalid;

  wire [ADDR_W-1:0] cur_awaddr = aw_full ? aw_q : s_axil_awaddr;
  wire [31:0]       cur_wdata  = w_full  ? w_q  : s_axil_wdata;
  wire [3:0]        cur_wstrb  = w_full  ? ws_q : s_axil_wstrb;
  wire              strb_ok    = (cur_wstrb == 4'hF);

  assign reg_we_o    = do_wr && strb_ok;
  assign reg_waddr_o = cur_awaddr;
  assign reg_wdata_o = cur_wdata;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_full <= 1'b0; w_full <= 1'b0; aw_q <= '0; w_q <= '0; ws_q <= '0;
      s_axil_bvalid <= 1'b0; s_axil_bresp <= RESP_OKAY;
    end else begin
      if (do_wr) begin
        aw_full <= 1'b0;
        w_full  <= 1'b0;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= (!strb_ok || reg_werr_i) ? RESP_SLVERR : RESP_OKAY;
      end else begin
        if (aw_hs) begin aw_full <= 1'b1; aw_q <= s_axil_awaddr; end
        if (w_hs)  begin w_full  <= 1'b1; w_q <= s_axil_wdata; ws_q <= s_axil_wstrb; end
        if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
      end
    end
  end

  // ---------------- read ----------------
  logic        r_first;     // first cycle of RVALID: data comes from the block
  logic [31:0] rdata_q;
  logic        rerr_q;

  assign s_axil_arready = !s_axil_rvalid;
  wire ar_hs = s_axil_arvalid && s_axil_arready;
  assign reg_re_o    = ar_hs;
  assign reg_raddr_o = s_axil_araddr;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s_axil_rvalid <= 1'b0; r_first <= 1'b0; rdata_q <= '0; rerr_q <= 1'b0;
      reg_raddr_q_o <= '0;
    end else begin
      r_first <= 1'b0;
      if (ar_hs) begin
        s_axil_rvalid <= 1'b1;
        r_first       <= 1'b1;
        reg_raddr_q_o <= s_axil_araddr;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
      if (r_first) begin
        rdata_q <= reg_rdata_i;
        rerr_q  <= reg_rerr_i;
      end
    end
  end

  assign s_axil_rdata = r_first ? reg_rdata_i : rdata_q;
  assign s_axil_rresp = (r_first ? reg_rerr_i : rerr_q) ? RESP_SLVERR : RESP_OKAY;

  // Protection bits are accepted but not used.
  logic unused;
  assign unused = ^{s_axil_awprot, s_axil_arprot};
endmodule
