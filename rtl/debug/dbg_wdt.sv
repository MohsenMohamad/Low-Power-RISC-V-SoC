// Watchdog timer (doc/DEBUG_SPEC.md section 8).
//
// Down-counter in clk_aon. Bark (pre-timeout interrupt) when COUNT <= BARK.
// Bite at 0: the hang is first logged in the error log (wdt_evt_o until
// wdt_evt_ack_i, or LOG_TIMEOUT cycles), then a PD_CPU reset is requested on
// cpu_rst_req_o for RST_PULSE cycles.
module dbg_wdt
  import dbg_pkg::*;
#(
  parameter int unsigned RST_PULSE   = 16,
  parameter int unsigned LOG_TIMEOUT = 64
) (
  input  logic        clk_aon_i,
  input  logic        rst_aon_ni,
  // AXI4-Lite slave (clk_aon)
  input  logic [11:0] s_axil_awaddr,
  input  logic [2:0]  s_axil_awprot,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [11:0] s_axil_araddr,
  input  logic [2:0]  s_axil_arprot,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // power state (clk_aon)
  input  logic [1:0]  pwr_state_i,
  // error log handshake
  output logic        wdt_evt_o,
  input  logic        wdt_evt_ack_i,
  // outputs
  output logic        cpu_rst_req_o,
  output logic        irq_o
);
  logic rst_a_n;
  dbg_rst_sync u_rs_a (.clk_i(clk_aon_i), .rst_ni(rst_aon_ni), .rst_no(rst_a_n));

  logic        reg_we, reg_re, reg_werr, reg_rerr;
  logic [11:0] reg_waddr, reg_raddr, reg_raddr_q;
  logic [31:0] reg_wdata, reg_rdata;

  dbg_axil_slave #(.ADDR_W(12)) u_axil (
    .clk_i(clk_aon_i), .rst_ni(rst_a_n),
    .s_axil_awaddr, .s_axil_awprot, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arprot, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_we_o(reg_we), .reg_waddr_o(reg_waddr), .reg_wdata_o(reg_wdata), .reg_werr_i(reg_werr),
    .reg_re_o(reg_re), .reg_raddr_o(reg_raddr), .reg_raddr_q_o(reg_raddr_q),
    .reg_rdata_i(reg_rdata), .reg_rerr_i(reg_rerr)
  );
  logic unused;
  assign unused = ^{reg_re, reg_raddr};

  localparam logic [11:0] A_ID = 12'h000, A_CTRL = 12'h004, A_LOAD = 12'h008, A_BARK = 12'h00C,
                          A_COUNT = 12'h010, A_KICK = 12'h014, A_STATUS = 12'h018, A_RST_CNT = 12'h01C;

  typedef enum logic [1:0] {W_RUN, W_LOG, W_RST} wst_t;
  wst_t        st_q;
  logic        en_q, bark_en_q, rst_en_q, pause_lp_q, lock_q;
  logic [31:0] load_q, bark_q, count_q, rst_cnt_q;
  logic        bark_st_q, bite_st_q, bad_kick_q;
  logic [7:0]  tmr_q;

  always_comb begin
    unique case (reg_waddr)
      A_CTRL, A_LOAD, A_BARK: reg_werr = lock_q;
      A_KICK, A_STATUS:       reg_werr = 1'b0;
      default:                reg_werr = 1'b1;
    endcase
  end

  wire wr_ok   = reg_we && !reg_werr;
  wire kick    = wr_ok && reg_waddr == A_KICK && reg_wdata == WDT_KICK_KEY;
  wire bad_kk  = wr_ok && reg_waddr == A_KICK && reg_wdata != WDT_KICK_KEY;
  wire en_rise = wr_ok && reg_waddr == A_CTRL && reg_wdata[0] && !en_q;
  wire paused  = pause_lp_q && (pwr_state_i == PS_SLEEP || pwr_state_i == PS_DSLEEP);
  wire bite    = st_q == W_RUN && en_q && count_q == 32'd0 && !kick && !en_rise;

  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      st_q <= W_RUN; en_q <= 1'b0; bark_en_q <= 1'b0; rst_en_q <= 1'b0; pause_lp_q <= 1'b1;
      lock_q <= 1'b0; load_q <= '1; bark_q <= '0; count_q <= '1; rst_cnt_q <= '0;
      bark_st_q <= 1'b0; bite_st_q <= 1'b0; bad_kick_q <= 1'b0; tmr_q <= '0;
    end else begin
      // ---- registers ----
      if (wr_ok) begin
        unique case (reg_waddr)
          A_CTRL: begin
            en_q <= reg_wdata[0]; bark_en_q <= reg_wdata[1]; rst_en_q <= reg_wdata[2];
            pause_lp_q <= reg_wdata[3];
            if (reg_wdata[31]) lock_q <= 1'b1;
          end
          A_LOAD: load_q <= reg_wdata;
          A_BARK: bark_q <= reg_wdata;
          A_STATUS: begin
            if (reg_wdata[0]) bark_st_q  <= 1'b0;
            if (reg_wdata[1]) bite_st_q  <= 1'b0;
            if (reg_wdata[3]) bad_kick_q <= 1'b0;
          end
          default: ;
        endcase
      end
      if (bad_kk) bad_kick_q <= 1'b1;
      // ---- counter ----
      if (kick || en_rise) begin
        count_q   <= (wr_ok && reg_waddr == A_LOAD) ? reg_wdata : load_q;
        bark_st_q <= 1'b0;
      end else if (st_q == W_RUN && en_q && !paused && count_q != 0) begin
        count_q <= count_q - 32'd1;
        if (count_q - 32'd1 <= bark_q) bark_st_q <= 1'b1;
      end
      // ---- bite sequence ----
      unique case (st_q)
        W_RUN: if (bite) begin
          st_q <= W_LOG; bite_st_q <= 1'b1; tmr_q <= '0;
        end
        W_LOG: begin
          tmr_q <= tmr_q + 8'd1;
          if (wdt_evt_ack_i || tmr_q == 8'(LOG_TIMEOUT - 1)) begin
            count_q <= load_q;
            tmr_q   <= '0;
            if (rst_en_q) begin st_q <= W_RST; rst_cnt_q <= rst_cnt_q + 32'd1; end
            else            st_q <= W_RUN;
          end
        end
        W_RST: begin
          tmr_q <= tmr_q + 8'd1;
          if (tmr_q == 8'(RST_PULSE - 1)) begin st_q <= W_RUN; tmr_q <= '0; end
        end
        default: st_q <= W_RUN;
      endcase
    end
  end

  assign wdt_evt_o     = (st_q == W_LOG);
  assign cpu_rst_req_o = (st_q == W_RST);
  assign irq_o         = bark_st_q && bark_en_q;

  always_comb begin
    reg_rdata = '0;
    reg_rerr  = 1'b0;
    unique case (reg_raddr_q)
      A_ID:      reg_rdata = id_word(BLK_WDT);
      A_CTRL:    reg_rdata = {lock_q, 27'd0, pause_lp_q, rst_en_q, bark_en_q, en_q};
      A_LOAD:    reg_rdata = load_q;
      A_BARK:    reg_rdata = bark_q;
      A_COUNT:   reg_rdata = count_q;
      A_STATUS:  reg_rdata = {27'd0, st_q == W_LOG, bad_kick_q, st_q == W_RST, bite_st_q, bark_st_q};
      A_RST_CNT: reg_rdata = rst_cnt_q;
      default:   reg_rerr  = 1'b1;
    endcase
  end
endmodule
