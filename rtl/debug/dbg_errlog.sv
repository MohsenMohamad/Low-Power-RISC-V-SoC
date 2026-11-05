// Error / crash log (doc/DEBUG_SPEC.md section 7).
//
// Last exception (cause, PC, tval, timestamp), last power transition and its
// result, watchdog bites, software errors. Sticky status in PD_AON, reset only
// by the AON power-on reset: survives SLEEP, DEEP_SLEEP and PD_CPU resets.
module dbg_errlog
  import dbg_pkg::*;
(
  input  logic        clk_aon_i,
  input  logic        rst_aon_ni,
  input  logic        clk_cpu_i,
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
  // CPU trap port (clk_cpu)
  input  logic        trap_valid_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_tval_i,
  // PMU (clk_aon)
  input  logic [1:0]  pwr_state_i,
  input  logic        pmu_evt_valid_i,
  input  logic [1:0]  pmu_evt_from_i,
  input  logic [1:0]  pmu_evt_to_i,
  input  logic [1:0]  pmu_evt_result_i,
  // watchdog (clk_aon)
  input  logic        wdt_evt_i,
  output logic        wdt_evt_ack_o,
  input  logic        wdt_rst_i,
  // outputs (clk_aon)
  output logic        irq_o,
  output logic        freeze_o
);
  localparam int unsigned S_EXC = 0, S_EXC_OVR = 1, S_PWR_ERR = 2, S_WDT_BITE = 3,
                          S_WDT_RST = 4, S_SW_ERR = 5, NS = 6;

  logic rst_a_n, rst_c_n;
  dbg_rst_sync u_rs_a (.clk_i(clk_aon_i), .rst_ni(rst_aon_ni), .rst_no(rst_a_n));
  dbg_rst_sync u_rs_c (.clk_i(clk_cpu_i), .rst_ni(rst_aon_ni), .rst_no(rst_c_n));

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
  logic unused_re;
  assign unused_re = ^{reg_re, reg_raddr};

  localparam logic [11:0] A_ID = 12'h000, A_STATUS = 12'h004, A_CTRL = 12'h008, A_IRQ_EN = 12'h00C,
                          A_FRZ_EN = 12'h010, A_SW_ERR = 12'h014, A_SW_CODE = 12'h018,
                          A_EXC_CAUSE = 12'h020, A_EXC_PC = 12'h024, A_EXC_TVAL = 12'h028,
                          A_EXC_TS = 12'h02C, A_EXC_CNT = 12'h030, A_PWR_LAST = 12'h040,
                          A_PWR_TS = 12'h044, A_PWR_ERR_LAST = 12'h048, A_PWR_ERR_TS = 12'h04C,
                          A_WDT_CNT = 12'h050, A_WDT_TS = 12'h054, A_WDT_PS = 12'h058,
                          A_TSTAMP = 12'h05C;

  always_comb begin
    unique case (reg_waddr)
      A_STATUS, A_CTRL, A_IRQ_EN, A_FRZ_EN, A_SW_ERR: reg_werr = 1'b0;
      default: reg_werr = 1'b1;
    endcase
  end

  // ======================= CPU side: exception capture =======================
  logic        req_c_q, ack_c;
  logic [31:0] h_cause_q, h_pc_q, h_tval_q;
  logic [3:0]  drop_c_q;
  wire busy_c = (req_c_q != ack_c);
  wire exc_c  = trap_valid_i && !trap_cause_i[31];

  always_ff @(posedge clk_cpu_i or negedge rst_c_n) begin
    if (!rst_c_n) begin
      req_c_q <= 1'b0; h_cause_q <= '0; h_pc_q <= '0; h_tval_q <= '0; drop_c_q <= '0;
    end else if (exc_c) begin
      if (!busy_c) begin
        h_cause_q <= trap_cause_i; h_pc_q <= trap_pc_i; h_tval_q <= trap_tval_i;
        req_c_q   <= ~req_c_q;
      end else begin
        drop_c_q <= drop_c_q + 4'd1;
      end
    end
  end

  // ======================= crossings =======================
  logic req_a, ack_a_q;
  logic [3:0] drop_a, drop_seen_q;
  dbg_sync u_s_req (.clk_i(clk_aon_i), .rst_ni(rst_a_n), .d_i(req_c_q), .q_o(req_a));
  dbg_sync u_s_ack (.clk_i(clk_cpu_i), .rst_ni(rst_c_n), .d_i(ack_a_q), .q_o(ack_c));
  dbg_gray_sync #(.WIDTH(4)) u_g_drop (
    .clk_src_i(clk_cpu_i), .rst_src_ni(rst_c_n), .bin_i(drop_c_q),
    .clk_dst_i(clk_aon_i), .rst_dst_ni(rst_a_n), .bin_o(drop_a));

  // ======================= AON side =======================
  logic [NS-1:0] status_q, irq_en_q, frz_en_q;
  logic          keep_first_q;
  logic [31:0]   ts_q, sw_code_q;
  logic [31:0]   exc_cause_q, exc_pc_q, exc_tval_q, exc_ts_q, exc_cnt_q;
  logic [5:0]    pwr_last_q, pwr_err_last_q;
  logic [15:0]   pwr_cnt_q;
  logic [31:0]   pwr_ts_q, pwr_err_ts_q, wdt_cnt_q, wdt_ts_q;
  logic [1:0]    wdt_ps_q;
  logic          wdt_logged_q, wdt_rst_q;

  wire new_exc = (req_a != ack_a_q);
  wire new_wdt = wdt_evt_i && !wdt_logged_q;

  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      status_q <= '0; irq_en_q <= '0; frz_en_q <= NS'(6'b011100); keep_first_q <= 1'b0;
      ts_q <= '0; sw_code_q <= '0; ack_a_q <= 1'b0; drop_seen_q <= '0;
      exc_cause_q <= '0; exc_pc_q <= '0; exc_tval_q <= '0; exc_ts_q <= '0; exc_cnt_q <= '0;
      pwr_last_q <= '0; pwr_err_last_q <= '0; pwr_cnt_q <= '0; pwr_ts_q <= '0; pwr_err_ts_q <= '0;
      wdt_cnt_q <= '0; wdt_ts_q <= '0; wdt_ps_q <= '0; wdt_logged_q <= 1'b0; wdt_rst_q <= 1'b0;
    end else begin
      automatic logic [NS-1:0] set = '0;
      ts_q <= ts_q + 32'd1;
      // register writes (W1C status first, so that same-cycle events win)
      if (reg_we) begin
        unique case (reg_waddr)
          A_STATUS: status_q <= status_q & ~reg_wdata[NS-1:0];
          A_CTRL:   keep_first_q <= reg_wdata[0];
          A_IRQ_EN: irq_en_q <= reg_wdata[NS-1:0];
          A_FRZ_EN: frz_en_q <= reg_wdata[NS-1:0];
          A_SW_ERR: begin set[S_SW_ERR] = 1'b1; sw_code_q <= reg_wdata; end
          default: ;
        endcase
      end
      // exception record
      if (new_exc) begin
        ack_a_q <= req_a;
        if (exc_cnt_q != 32'hFFFF_FFFF) exc_cnt_q <= exc_cnt_q + 32'd1;
        if (!(keep_first_q && status_q[S_EXC])) begin
          exc_cause_q <= h_cause_q; exc_pc_q <= h_pc_q; exc_tval_q <= h_tval_q; exc_ts_q <= ts_q;
        end
        set[S_EXC] = 1'b1;
      end
      drop_seen_q <= drop_a;
      if (drop_a != drop_seen_q) set[S_EXC_OVR] = 1'b1;
      // power transitions
      if (pmu_evt_valid_i) begin
        pwr_last_q <= {pmu_evt_result_i, pmu_evt_to_i, pmu_evt_from_i};
        pwr_ts_q   <= ts_q;
        if (pwr_cnt_q != 16'hFFFF) pwr_cnt_q <= pwr_cnt_q + 16'd1;
        if (pmu_evt_result_i != 2'd0) begin
          pwr_err_last_q <= {pmu_evt_result_i, pmu_evt_to_i, pmu_evt_from_i};
          pwr_err_ts_q   <= ts_q;
          set[S_PWR_ERR] = 1'b1;
        end
      end
      // watchdog
      if (new_wdt) begin
        wdt_logged_q <= 1'b1;
        wdt_cnt_q    <= wdt_cnt_q + 32'd1;
        wdt_ts_q     <= ts_q;
        wdt_ps_q     <= pwr_state_i;
        set[S_WDT_BITE] = 1'b1;
      end else if (!wdt_evt_i) begin
        wdt_logged_q <= 1'b0;
      end
      wdt_rst_q <= wdt_rst_i;
      if (wdt_rst_i && !wdt_rst_q) set[S_WDT_RST] = 1'b1;
      if (set != '0) begin
        if (reg_we && reg_waddr == A_STATUS) status_q <= (status_q & ~reg_wdata[NS-1:0]) | set;
        else                                 status_q <= status_q | set;
      end
    end
  end

  assign wdt_evt_ack_o = wdt_logged_q;
  assign irq_o    = |(status_q & irq_en_q);
  assign freeze_o = |(status_q & frz_en_q);

  always_comb begin
    reg_rdata = '0;
    reg_rerr  = 1'b0;
    unique case (reg_raddr_q)
      A_ID:           reg_rdata = id_word(BLK_ERRLOG);
      A_STATUS:       reg_rdata = 32'(status_q);
      A_CTRL:         reg_rdata = {31'd0, keep_first_q};
      A_IRQ_EN:       reg_rdata = 32'(irq_en_q);
      A_FRZ_EN:       reg_rdata = 32'(frz_en_q);
      A_SW_CODE:      reg_rdata = sw_code_q;
      A_EXC_CAUSE:    reg_rdata = exc_cause_q;
      A_EXC_PC:       reg_rdata = exc_pc_q;
      A_EXC_TVAL:     reg_rdata = exc_tval_q;
      A_EXC_TS:       reg_rdata = exc_ts_q;
      A_EXC_CNT:      reg_rdata = exc_cnt_q;
      A_PWR_LAST:     reg_rdata = {pwr_cnt_q, 10'd0, pwr_last_q};
      A_PWR_TS:       reg_rdata = pwr_ts_q;
      A_PWR_ERR_LAST: reg_rdata = {16'd0, 10'd0, pwr_err_last_q};
      A_PWR_ERR_TS:   reg_rdata = pwr_err_ts_q;
      A_WDT_CNT:      reg_rdata = wdt_cnt_q;
      A_WDT_TS:       reg_rdata = wdt_ts_q;
      A_WDT_PS:       reg_rdata = {30'd0, wdt_ps_q};
      A_TSTAMP:       reg_rdata = ts_q;
      default:        reg_rerr  = 1'b1;
    endcase
  end
endmodule
