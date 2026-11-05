// Trace buffer (doc/DEBUG_SPEC.md section 5).
//
// Circular buffer of retired PC / instruction / timestamp with start/stop
// triggers (PC match, exception, power-state change) and freeze on error.
// Capture logic runs on clk_cpu (AON-powered flops), registers and readout on
// clk_aon; the buffer stays readable while PD_CPU is off.
module dbg_trace
  import dbg_pkg::*;
#(
  parameter int unsigned DEPTH = 64,
  localparam int unsigned AW = $clog2(DEPTH)
) (
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
  // CPU retire / trap port (clk_cpu)
  input  logic        ret_valid_i,
  input  logic [31:0] ret_pc_i,
  input  logic [31:0] ret_insn_i,
  input  logic        trap_valid_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_tval_i,
  // power state (clk_aon) and freeze request (clk_aon)
  input  logic [1:0]  pwr_state_i,
  input  logic        freeze_i
);
  initial begin
    if (DEPTH < 16 || DEPTH > 128 || (1 << AW) != DEPTH)
      $fatal(1, "dbg_trace: DEPTH must be a power of 2 in 16..128");
  end

  // ======================= resets =======================
  logic rst_a_n, rst_c_n;
  dbg_rst_sync u_rs_a (.clk_i(clk_aon_i), .rst_ni(rst_aon_ni), .rst_no(rst_a_n));
  dbg_rst_sync u_rs_c (.clk_i(clk_cpu_i), .rst_ni(rst_aon_ni), .rst_no(rst_c_n));

  // ======================= AON: registers =======================
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

  localparam logic [11:0] A_ID = 12'h000, A_CTRL = 12'h004, A_STATUS = 12'h008, A_TRIG = 12'h00C,
                          A_START = 12'h010, A_STOP = 12'h014, A_MASK = 12'h018, A_WPTR = 12'h01C,
                          A_COUNT = 12'h020, A_DEPTH = 12'h024, A_TOTAL = 12'h028, A_TSTAMP = 12'h02C;

  logic        en_q, log_trap_q, log_pwr_q, frz_exc_q, frz_err_q, sw_frz_q;
  logic [1:0]  start_sel_q, stop_sel_q;
  logic [31:0] start_pc_q, stop_pc_q, pc_mask_q;
  logic        clr_req_q;           // toggle
  logic [31:0] ts_q;

  wire wr_cfg  = reg_we && (reg_waddr == A_TRIG || reg_waddr == A_START ||
                            reg_waddr == A_STOP || reg_waddr == A_MASK);
  wire wr_ctrl = reg_we && reg_waddr == A_CTRL;
  wire do_clr  = wr_ctrl && reg_wdata[1];

  always_comb begin
    reg_werr = 1'b0;
    unique case (reg_waddr)
      A_CTRL:                       reg_werr = 1'b0;
      A_TRIG, A_START, A_STOP, A_MASK: reg_werr = en_q;   // config only while disabled
      default:                      reg_werr = 1'b1;      // RO or unmapped
    endcase
  end

  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      en_q <= 1'b0; log_trap_q <= 1'b1; log_pwr_q <= 1'b0; frz_exc_q <= 1'b1; frz_err_q <= 1'b1;
      sw_frz_q <= 1'b0; start_sel_q <= TRIG_NONE; stop_sel_q <= TRIG_NONE;
      start_pc_q <= '0; stop_pc_q <= '0; pc_mask_q <= '1; clr_req_q <= 1'b0; ts_q <= '0;
    end else begin
      ts_q <= ts_q + 32'd1;
      if (wr_ctrl) begin
        en_q       <= reg_wdata[0];
        log_trap_q <= reg_wdata[3];
        log_pwr_q  <= reg_wdata[4];
        frz_exc_q  <= reg_wdata[5];
        frz_err_q  <= reg_wdata[6];
        if (reg_wdata[2]) sw_frz_q <= 1'b1;
        if (reg_wdata[1]) begin sw_frz_q <= 1'b0; clr_req_q <= ~clr_req_q; end
      end
      if (wr_cfg && !reg_werr) begin
        unique case (reg_waddr)
          A_TRIG:  begin start_sel_q <= reg_wdata[1:0]; stop_sel_q <= reg_wdata[5:4]; end
          A_START: start_pc_q <= reg_wdata;
          A_STOP:  stop_pc_q  <= reg_wdata;
          A_MASK:  pc_mask_q  <= reg_wdata;
          default: ;
        endcase
      end
    end
  end

  // Power-state change detector: 4-bit event counter (Gray-synchronised to
  // clk_cpu) and the new state.
  logic [1:0] pwr_q, pwr_new_q;
  logic [3:0] pwr_cnt_q;
  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      pwr_q <= PS_RUN; pwr_new_q <= PS_RUN; pwr_cnt_q <= '0;
    end else begin
      pwr_q <= pwr_state_i;
      if (pwr_state_i != pwr_q) begin
        pwr_cnt_q <= pwr_cnt_q + 4'd1;
        pwr_new_q <= pwr_state_i;
      end
    end
  end

  // Only cause[31] and cause[7:0] are recorded; address bits below the
  // 16-byte entry stride and bit 10 (window above DEPTH=64) select words.
  logic unused_a;
  assign unused_a = ^{trap_cause_i[30:8], reg_raddr[10], reg_raddr[3:0]};

  wire frz_req_a = sw_frz_q || (frz_err_q && freeze_i);

  // ======================= crossings AON -> CPU =======================
  logic        en_c, frz_req_c, clr_req_c;
  logic        log_trap_c, log_pwr_c, frz_exc_c;
  logic [1:0]  pwr_new_c;
  logic [3:0]  pwr_cnt_c;
  logic [31:0] ts_c;

  dbg_sync #(.WIDTH(7)) u_s_ctl (
    .clk_i(clk_cpu_i), .rst_ni(rst_c_n),
    .d_i({en_q, frz_req_a, clr_req_q, log_trap_q, log_pwr_q, frz_exc_q, 1'b0}),
    .q_o({en_c, frz_req_c, clr_req_c, log_trap_c, log_pwr_c, frz_exc_c, unused_c0}));
  logic unused_c0;
  dbg_sync #(.WIDTH(2)) u_s_pnew (.clk_i(clk_cpu_i), .rst_ni(rst_c_n), .d_i(pwr_new_q), .q_o(pwr_new_c));
  dbg_gray_sync #(.WIDTH(4)) u_g_pcnt (
    .clk_src_i(clk_aon_i), .rst_src_ni(rst_a_n), .bin_i(pwr_cnt_q),
    .clk_dst_i(clk_cpu_i), .rst_dst_ni(rst_c_n), .bin_o(pwr_cnt_c));
  dbg_gray_sync #(.WIDTH(32)) u_g_ts (
    .clk_src_i(clk_aon_i), .rst_src_ni(rst_a_n), .bin_i(ts_q),
    .clk_dst_i(clk_cpu_i), .rst_dst_ni(rst_c_n), .bin_o(ts_c));
  // Trigger configuration: quasi-static (only writable while EN=0, and EN
  // reaches clk_cpu through a 2-flop synchroniser after it).

  // ======================= CPU: capture =======================
  typedef enum logic [1:0] {C_IDLE, C_ARMED, C_ACTIVE, C_STOPPED} cst_t;
  cst_t        cst_q;
  logic        frozen_q, frz_req_prev_q, clr_seen_q, clr_ack_q, ovf_q;
  logic [3:0]  pwr_seen_q;
  logic [31:0] wcnt_q;

  wire clr_c   = (clr_req_c != clr_seen_q);
  wire pwr_evt = (pwr_cnt_c != pwr_seen_q);
  wire exc     = trap_valid_i && !trap_cause_i[31];

  function automatic logic pc_hit(input logic [31:0] pc, input logic [31:0] ref_pc,
                                  input logic [31:0] mask);
    return ((pc ^ ref_pc) & mask) == 32'd0;
  endfunction

  function automatic logic trig_hit(input logic [1:0] sel, input logic [31:0] ref_pc);
    unique case (sel)
      TRIG_PC:  return ret_valid_i && pc_hit(ret_pc_i, ref_pc, pc_mask_q);
      TRIG_EXC: return exc;
      TRIG_PWR: return pwr_evt;
      default:  return 1'b0;
    endcase
  endfunction

  wire start_hit = (start_sel_q == TRIG_NONE) || trig_hit(start_sel_q, start_pc_q);
  wire stop_hit  = trig_hit(stop_sel_q, stop_pc_q);
  wire capturing = en_c && !frozen_q && !clr_c &&
                   (cst_q == C_ACTIVE || (cst_q == C_ARMED && start_hit));

  // Entries produced this cycle (order: retire, trap, power).
  typedef struct packed { logic [31:0] info, ts, data, pc; } entry_t;
  entry_t e_ret, e_trap, e_pwr;
  always_comb begin
    e_ret  = '{info: {30'd0, TE_RETIRE}, ts: ts_c, data: ret_insn_i, pc: ret_pc_i};
    e_trap = '{info: {trap_cause_i[31], 7'd0, trap_cause_i[7:0], 12'd0, 2'b00, TE_TRAP},
               ts: ts_c, data: trap_tval_i, pc: trap_pc_i};
    e_pwr  = '{info: {28'd0, pwr_new_c, TE_PWR}, ts: ts_c, data: 32'd0, pc: 32'd0};
  end
  wire v_ret  = capturing && ret_valid_i;
  wire v_trap = capturing && trap_valid_i && log_trap_c;
  wire v_pwr  = capturing && pwr_evt && log_pwr_c;

  // 4-entry FIFO in front of the single RAM write port.
  localparam int unsigned FD = 4;
  entry_t      fifo_q [FD];
  logic [2:0]  fcnt_q;
  logic [1:0]  frd_q;
  logic [2:0]  n_in;
  assign n_in = 3'(v_ret) + 3'(v_trap) + 3'(v_pwr);
  wire         f_pop  = (fcnt_q != 0);
  wire  [2:0]  f_space = 3'(FD) - fcnt_q + 3'(f_pop);
  wire         f_ovf  = n_in > f_space;

  always_ff @(posedge clk_cpu_i or negedge rst_c_n) begin
    if (!rst_c_n) begin
      fcnt_q <= '0; frd_q <= '0;
      for (int i = 0; i < FD; i++) fifo_q[i] <= '0;
    end else if (clr_c) begin
      fcnt_q <= '0; frd_q <= '0;
    end else begin
      automatic logic [1:0] wi = 2'(frd_q + 2'(fcnt_q));
      automatic logic [2:0] pushed = '0;
      if (!f_ovf) begin
        if (v_ret)  begin fifo_q[2'(wi + 2'(pushed))] <= e_ret;  pushed = pushed + 3'd1; end
        if (v_trap) begin fifo_q[2'(wi + 2'(pushed))] <= e_trap; pushed = pushed + 3'd1; end
        if (v_pwr)  begin fifo_q[2'(wi + 2'(pushed))] <= e_pwr;  pushed = pushed + 3'd1; end
      end
      fcnt_q <= fcnt_q + pushed - 3'(f_pop);
      if (f_pop) frd_q <= frd_q + 2'd1;
    end
  end

  always_ff @(posedge clk_cpu_i or negedge rst_c_n) begin
    if (!rst_c_n) begin
      cst_q <= C_IDLE; frozen_q <= 1'b0; frz_req_prev_q <= 1'b0; clr_seen_q <= 1'b0; clr_ack_q <= 1'b0;
      ovf_q <= 1'b0; pwr_seen_q <= '0; wcnt_q <= '0;
    end else begin
      pwr_seen_q     <= pwr_cnt_c;
      frz_req_prev_q <= frz_req_c;
      // acknowledge one cycle after the clear, when the Gray copy of the
      // write count (registered from wcnt_q) already holds 0
      clr_ack_q      <= clr_seen_q;
      if (clr_c) begin
        clr_seen_q <= clr_req_c;
        cst_q      <= en_c ? C_ARMED : C_IDLE;
        frozen_q   <= 1'b0;
        ovf_q      <= 1'b0;
        wcnt_q     <= '0;
      end else begin
        if (f_pop) wcnt_q <= wcnt_q + 32'd1;
        if (f_ovf) ovf_q <= 1'b1;
        if ((frz_req_c && !frz_req_prev_q) || (exc && frz_exc_c)) frozen_q <= 1'b1;
        if (!en_c) cst_q <= C_IDLE;
        else begin
          unique case (cst_q)
            C_IDLE:    cst_q <= C_ARMED;
            C_ARMED:   if (!frozen_q && start_hit) cst_q <= stop_hit ? C_STOPPED : C_ACTIVE;
            C_ACTIVE:  if (!frozen_q && stop_hit) cst_q <= C_STOPPED;
            default:   ;
          endcase
        end
      end
    end
  end

  // ======================= RAM =======================
  entry_t ram_rd;
  logic   ram_re;
  logic [AW-1:0] ram_raddr;
  assign ram_re    = reg_re && reg_raddr[11];
  assign ram_raddr = reg_raddr[AW+3:4];

  dbg_ram_2c #(.DEPTH(DEPTH), .WIDTH(128)) u_ram (
    .clk_w_i(clk_cpu_i), .we_i(f_pop && !clr_c), .waddr_i(wcnt_q[AW-1:0]), .wdata_i(fifo_q[frd_q]),
    .clk_r_i(clk_aon_i), .re_i(ram_re), .raddr_i(ram_raddr), .rdata_o(ram_rd));

  // ======================= crossings CPU -> AON =======================
  logic [31:0] wcnt_a;
  logic        st_active_a, st_armed_a, st_stopped_a, st_frozen_a, st_ovf_a, clr_ack_a;
  dbg_gray_sync #(.WIDTH(32)) u_g_wcnt (
    .clk_src_i(clk_cpu_i), .rst_src_ni(rst_c_n), .bin_i(wcnt_q),
    .clk_dst_i(clk_aon_i), .rst_dst_ni(rst_a_n), .bin_o(wcnt_a));
  dbg_sync #(.WIDTH(6)) u_s_st (
    .clk_i(clk_aon_i), .rst_ni(rst_a_n),
    .d_i({cst_q == C_ACTIVE, cst_q == C_ARMED, cst_q == C_STOPPED, frozen_q, ovf_q, clr_ack_q}),
    .q_o({st_active_a, st_armed_a, st_stopped_a, st_frozen_a, st_ovf_a, clr_ack_a}));

  // Displayed write count: held while a clear is in flight and for two
  // cycles after its acknowledge (the Gray copy jumps to 0 on a clear).
  wire        clr_pend = (clr_req_q != clr_ack_a);
  logic [1:0] hold_q;
  logic [31:0] total_q;
  logic        wrapped_q;
  always_ff @(posedge clk_aon_i or negedge rst_a_n) begin
    if (!rst_a_n) begin
      hold_q <= '0; total_q <= '0; wrapped_q <= 1'b0;
    end else begin
      if (clr_pend || do_clr) hold_q <= 2'd3;
      else if (hold_q != 0)   hold_q <= hold_q - 2'd1;
      if (do_clr) begin
        total_q <= '0; wrapped_q <= 1'b0;
      end else if (hold_q == 0 && !clr_pend) begin
        total_q <= wcnt_a;
        if (wcnt_a >= 32'(DEPTH)) wrapped_q <= 1'b1;
      end
    end
  end

  // ======================= read mux =======================
  always_comb begin
    reg_rdata = '0;
    reg_rerr  = 1'b0;
    if (reg_raddr_q[11]) begin
      if (reg_raddr_q[10:4] < 7'(DEPTH)) begin
        unique case (reg_raddr_q[3:2])
          2'd0: reg_rdata = ram_rd.pc;
          2'd1: reg_rdata = ram_rd.data;
          2'd2: reg_rdata = ram_rd.ts;
          default: reg_rdata = ram_rd.info;
        endcase
      end
    end else begin
      unique case (reg_raddr_q)
        A_ID:     reg_rdata = id_word(BLK_TRACE);
        A_CTRL:   reg_rdata = {25'd0, frz_err_q, frz_exc_q, log_pwr_q, log_trap_q, sw_frz_q, 1'b0, en_q};
        A_STATUS: reg_rdata = {25'd0, st_ovf_a, clr_pend, st_armed_a, st_stopped_a, wrapped_q,
                               st_frozen_a, st_active_a};
        A_TRIG:   reg_rdata = {26'd0, stop_sel_q, 2'd0, start_sel_q};
        A_START:  reg_rdata = start_pc_q;
        A_STOP:   reg_rdata = stop_pc_q;
        A_MASK:   reg_rdata = pc_mask_q;
        A_WPTR:   reg_rdata = 32'(total_q[AW-1:0]);
        A_COUNT:  reg_rdata = wrapped_q ? 32'(DEPTH) : 32'(total_q[AW-1:0]);
        A_DEPTH:  reg_rdata = 32'(DEPTH);
        A_TOTAL:  reg_rdata = total_q;
        A_TSTAMP: reg_rdata = ts_q;
        default:  reg_rerr  = 1'b1;
      endcase
    end
  end
endmodule
