// Event counters (doc/DEBUG_SPEC.md section 6).
//
// clk_cpu domain: I$/D$ hit/miss and stall cycles (Gray-synchronised to
// clk_aon). clk_aon domain: time in each power state (64-bit), wake count,
// DVFS change count, power transition count. Freeze / clear controls.
// Cycle and instret counts are the CPU's own CSRs and are not duplicated.
module dbg_evcnt
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
  // cache / pipeline events (clk_cpu)
  input  logic        ic_hit_i,
  input  logic        ic_miss_i,
  input  logic        dc_hit_i,
  input  logic        dc_miss_i,
  input  logic        stall_i,
  // power (clk_aon)
  input  logic [1:0]  pwr_state_i,
  input  logic [1:0]  dvfs_op_i,
  input  logic        freeze_i
);
  localparam int unsigned NC = 5;   // clk_cpu counters

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

  localparam logic [11:0] A_ID = 12'h000, A_CTRL = 12'h004, A_STATUS = 12'h008,
                          A_CNT0 = 12'h010, A_WAKE = 12'h024, A_DVFS = 12'h028,
                          A_TRANS = 12'h02C, A_T0 = 12'h030, A_PSTATE = 12'h050;

  // ---------------- AON control ----------------
  logic       frz_q, frz_err_q, clr_req_q;
  logic [4:0] ovf_q;
  wire wr_ctrl = reg_we && reg_waddr == A_CTRL;
  wire wr_stat = reg_we && reg_waddr == A_STATUS;
  wire do_clr  = wr_ctrl && reg_wdata[1];
  wire frozen  = frz_q || (frz_err_q && freeze_i);

  assign reg_werr = !(reg_waddr == A_CTRL || reg_waddr == A_STATUS);

  // ---------------- clk_cpu counters ----------------
  logic frozen_c, clr_req_c, clr_seen_q, clr_ack_q;
  dbg_sync #(.WIDTH(2)) u_s_ctl (.clk_i(clk_cpu_i), .rst_ni(rst_c_n),
                                 .d_i({frozen, clr_req_q}), .q_o({frozen_c, clr_req_c}));
  wire clr_c = (clr_req_c != clr_seen_q);

  logic [31:0] cnt_c [NC];
  logic [NC-1:0] ovf_c;          // toggles on every wrap (Gray-safe 1-bit)
  wire  [NC-1:0] ev = {stall_i, dc_miss_i, dc_hit_i, ic_miss_i, ic_hit_i};

  always_ff @(posedge clk_cpu_i or negedge rst_c_n) begin
    if (!rst_c_n) begin
      clr_seen_q <= 1'b0; clr_ack_q <= 1'b0; ovf_c <= '0;
      for (int i = 0; i < NC; i++) cnt_c[i] <= '0;
    end else begin
      // acknowledge one cycle after the clear, when the Gray copies
      // (registered from cnt_c) already hold 0
      clr_ack_q <= clr_seen_q;
      if (clr_c) begin
        clr_seen_q <= clr_req_c;
        for (int i = 0; i < NC; i++) cnt_c[i] <= '0;
      end else if (!frozen_c) begin
        for (int i = 0; i < NC; i++) begin
          if (ev[i]) begin
            cnt_c[i] <= cnt_c[i] + 32'd1;
            if (cnt_c[i] == 32'hFFFF_FFFF) ovf_c[i] <= ~ovf_c[i];
          end
        end
      end
    end
  end

  logic [31:0] cnt_a [NC];
  for (genvar i = 0; i < NC; i++) begin : g_x
    dbg_gray_sync #(.WIDTH(32)) u_g (
      .clk_src_i(clk_cpu_i), .rst_src_ni(rst_c_n), .bin_i(cnt_c[i]),
      .clk_dst_i(clk_aon_i), .rst_dst_ni(rst_a_n), .bin_o(cnt_a[i]));
  end
  logic [NC-1:0] ovf_a, ovf_prev_q;
  logic          clr_ack_a;
  dbg_sync #(.WIDTH(NC + 1)) u_s_back (.clk_i(clk_aon_i), .rst_ni(rst_a_n),
                                       .d_i({ovf_c, clr_ack_q}), .q_o({ovf_a, clr_ack_a}));

  wire clr_pend = (clr_req_q != clr_ack_a);
  logic [1:0]  hold_q;
  logic [31:0] disp_q [NC];

  // ---------------- AON counters ----------------
  logic [1:0]  ps_q, op_q;
  logic [31:0] wake_q, dvfs_q, trans_q;
  logic [63:0] t_q [4];
  logic [31:0] hi_shadow_q, lo_shadow_q;

  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      frz_q <= 1'b0; frz_err_q <= 1'b0; clr_req_q <= 1'b0; ovf_q <= '0; ovf_prev_q <= '0;
      hold_q <= '0; ps_q <= PS_RUN; op_q <= '0; wake_q <= '0; dvfs_q <= '0; trans_q <= '0;
      hi_shadow_q <= '0; lo_shadow_q <= '0;
      for (int i = 0; i < NC; i++) disp_q[i] <= '0;
      for (int i = 0; i < 4; i++) t_q[i] <= '0;
    end else begin
      ps_q <= pwr_state_i;
      op_q <= dvfs_op_i;
      ovf_prev_q <= ovf_a;
      if (wr_ctrl) begin
        frz_q     <= reg_wdata[0];
        frz_err_q <= reg_wdata[2];
        if (reg_wdata[1]) clr_req_q <= ~clr_req_q;
      end
      // overflow flags (W1C), set on every toggle of the synchronised bit
      for (int i = 0; i < NC; i++) begin
        if (ovf_a[i] != ovf_prev_q[i] && !clr_pend && hold_q == 0) ovf_q[i] <= 1'b1;
        else if (wr_stat && reg_wdata[8+i]) ovf_q[i] <= 1'b0;
      end
      if (clr_pend || do_clr) hold_q <= 2'd3;
      else if (hold_q != 0)   hold_q <= hold_q - 2'd1;
      if (do_clr) begin
        for (int i = 0; i < NC; i++) disp_q[i] <= '0;
      end else if (!clr_pend && hold_q == 0) begin
        for (int i = 0; i < NC; i++) disp_q[i] <= cnt_a[i];
      end
      if (do_clr) begin
        wake_q <= '0; dvfs_q <= '0; trans_q <= '0; ovf_q <= '0;
        for (int i = 0; i < 4; i++) t_q[i] <= '0;
      end else if (!frozen) begin
        t_q[ps_q] <= t_q[ps_q] + 64'd1;
        if (pwr_state_i != ps_q) begin
          trans_q <= trans_q + 32'd1;
          if (pwr_state_i == PS_RUN && (ps_q == PS_SLEEP || ps_q == PS_DSLEEP)) wake_q <= wake_q + 32'd1;
        end
        if (dvfs_op_i != op_q) dvfs_q <= dvfs_q + 32'd1;
      end
      // 64-bit coherent read: LO read latches HI
      if (reg_re && reg_raddr >= A_T0 && reg_raddr < A_PSTATE && !reg_raddr[2])
        {hi_shadow_q, lo_shadow_q} <= t_q[reg_raddr[4:3]];
    end
  end

  always_comb begin
    reg_rdata = '0;
    reg_rerr  = 1'b0;
    if (reg_raddr_q >= A_CNT0 && reg_raddr_q < A_WAKE) begin
      reg_rdata = disp_q[3'((reg_raddr_q - A_CNT0) >> 2)];
    end else if (reg_raddr_q >= A_T0 && reg_raddr_q < A_PSTATE) begin
      // LO latches the full 64-bit value; HI returns the word latched by LO
      reg_rdata = reg_raddr_q[2] ? hi_shadow_q : lo_shadow_q;
    end else begin
      unique case (reg_raddr_q)
        A_ID:     reg_rdata = id_word(BLK_EVCNT);
        A_CTRL:   reg_rdata = {29'd0, frz_err_q, 1'b0, frz_q};
        A_STATUS: reg_rdata = {19'd0, ovf_q, 6'd0, clr_pend, frozen};
        A_WAKE:   reg_rdata = wake_q;
        A_DVFS:   reg_rdata = dvfs_q;
        A_TRANS:  reg_rdata = trans_q;
        A_PSTATE: reg_rdata = {26'd0, op_q, 2'd0, ps_q};
        default:  reg_rerr  = 1'b1;
      endcase
    end
  end
endmodule
