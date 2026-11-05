// Class-based constrained-random testbench for dbg_wdt.
//
// Tests (+TEST=<name>):
//   wdt_rand  random LOAD / BARK / CTRL, kicks (good and bad keys), power
//             states (pause in SLEEP / DEEP_SLEEP), error-log acknowledge
//             delays (including none: 64-cycle timeout path), W1C
//   wdt_lock  LOCK: CTRL / LOAD / BARK become read-only (SLVERR), kick and
//             bite still work, LOCK cannot be cleared
//
// A cycle-exact model follows the decoded register writes and is compared
// with irq_o / wdt_evt_o / cpu_rst_req_o every cycle and with COUNT /
// STATUS / RST_CNT reads. SVA checks the specification rules directly.
`timescale 1ns/1ps
module tb_wdt;
  import dbg_pkg::*;
  import dbg_tb_pkg::*;

  localparam int unsigned RST_PULSE = 16, LOG_TIMEOUT = 64;

  logic clk_aon = 1'b0, rst_n = 1'b0;
  clk_cfg ccfg;
  int unsigned seed = 1;
  string test = "wdt_rand";
  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("TEST=%s", test));
    ccfg = new();
    if (ccfg.randomize() == 0) $fatal(1, "clk_cfg randomize failed");
    $display("tb_wdt: test=%s seed=%0d aon_half=%0dps", test, seed, ccfg.aon_half_ps);
    fork forever #(ccfg.aon_half_ps * 1ps) clk_aon = ~clk_aon; join_none
  end

  dbg_axil_if axi (.clk(clk_aon), .rst_n(rst_n));
  logic [1:0] pwr_state = PS_RUN;
  logic       wdt_evt, wdt_ack = 1'b0, rst_req, irq;

  dbg_wdt #(.RST_PULSE(RST_PULSE), .LOG_TIMEOUT(LOG_TIMEOUT)) dut (
    .clk_aon_i(clk_aon), .rst_aon_ni(rst_n),
    .s_axil_awaddr(axi.awaddr[11:0]), .s_axil_awprot(axi.awprot), .s_axil_awvalid(axi.awvalid),
    .s_axil_awready(axi.awready), .s_axil_wdata(axi.wdata), .s_axil_wstrb(axi.wstrb),
    .s_axil_wvalid(axi.wvalid), .s_axil_wready(axi.wready), .s_axil_bresp(axi.bresp),
    .s_axil_bvalid(axi.bvalid), .s_axil_bready(axi.bready), .s_axil_araddr(axi.araddr[11:0]),
    .s_axil_arprot(axi.arprot), .s_axil_arvalid(axi.arvalid), .s_axil_arready(axi.arready),
    .s_axil_rdata(axi.rdata), .s_axil_rresp(axi.rresp), .s_axil_rvalid(axi.rvalid),
    .s_axil_rready(axi.rready),
    .pwr_state_i(pwr_state), .wdt_evt_o(wdt_evt), .wdt_evt_ack_i(wdt_ack),
    .cpu_rst_req_o(rst_req), .irq_o(irq));

  dbg_axil_sva #(.AW(12)) u_axi_sva (
    .clk(clk_aon), .rst_n(rst_n),
    .awaddr(axi.awaddr[11:0]), .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wvalid(axi.wvalid), .wready(axi.wready),
    .bresp(axi.bresp), .bvalid(axi.bvalid), .bready(axi.bready),
    .araddr(axi.araddr[11:0]), .arvalid(axi.arvalid), .arready(axi.arready),
    .rdata(axi.rdata), .rresp(axi.rresp), .rvalid(axi.rvalid), .rready(axi.rready));

  localparam logic [13:0] R_CTRL = 14'h004, R_LOAD = 14'h008, R_BARK = 14'h00C, R_COUNT = 14'h010,
                          R_KICK = 14'h014, R_STATUS = 14'h018, R_RST_CNT = 14'h01C;

  // ---------------- cycle-exact model ----------------
  typedef enum {M_RUN, M_LOG, M_RST} mst_e;
  mst_e        m_st = M_RUN;
  bit          m_en, m_bark_en, m_rst_en, m_pause = 1, m_lock;
  logic [31:0] m_load = '1, m_bark = 0, m_count = '1, m_rst_cnt = 0;
  bit          m_bark_st, m_bite_st, m_bad, m_rst_dis;
  int unsigned m_tmr;
  logic [31:0] exp_rd[$];          // expected data of reads in flight
  int unsigned n_bites, n_timeouts, n_resets, n_paused;

  always @(posedge clk_aon) begin
    if (rst_n) begin
      automatic bit         we = dut.reg_we;
      automatic logic [11:0] a = dut.reg_waddr;
      automatic logic [31:0] d = dut.reg_wdata;
      automatic bit werr = (a == 12'h004 || a == 12'h008 || a == 12'h00C) ? m_lock :
                           (a == 12'h014 || a == 12'h018) ? 1'b0 : 1'b1;
      automatic bit wr_ok = we && !werr;
      automatic bit kick = wr_ok && a == 12'h014 && d == WDT_KICK_KEY;
      automatic bit en_rise = wr_ok && a == 12'h004 && d[0] && !m_en;
      automatic bit paused = m_pause && (pwr_state == PS_SLEEP || pwr_state == PS_DSLEEP);
      automatic bit bite = m_st == M_RUN && m_en && m_count == 0 && !kick && !en_rise;
      if (dut.count_q !== m_count) check(0, $sformatf("COUNT vs model: dut=%0d model=%0d", dut.count_q, m_count));
      // outputs before the edge must match the model state
      if (wdt_evt !== (m_st == M_LOG)) check(0, "wdt_evt_o vs model");
      if (rst_req !== (m_st == M_RST)) check(0, "cpu_rst_req_o vs model");
      if (irq !== (m_bark_st && m_bark_en)) check(0, "irq_o vs model");
      // W1C first (a same-cycle set wins, as in the RTL)
      if (wr_ok && a == 12'h018) begin
        if (d[0]) m_bark_st = 0; if (d[1]) m_bite_st = 0; if (d[3]) m_bad = 0;
      end
      if (wr_ok && a == 12'h014 && d != WDT_KICK_KEY) m_bad = 1;
      if (kick || en_rise) begin
        m_count = m_load; m_bark_st = 0;
      end else if (m_st == M_RUN && m_en && !paused && m_count != 0) begin
        m_count--;
        if (m_count <= m_bark) m_bark_st = 1;
      end
      if (m_st == M_RUN && m_en && paused && m_count != 0) n_paused++;
      case (m_st)
        M_RUN: if (bite) begin m_st = M_LOG; m_bite_st = 1; m_tmr = 0; n_bites++; end
        M_LOG: begin
          if (wdt_ack || m_tmr == LOG_TIMEOUT - 1) begin
            if (!wdt_ack) n_timeouts++;
            m_count = m_load; m_tmr = 0;
            if (m_rst_en) begin m_st = M_RST; m_rst_cnt++; n_resets++; end
            else m_st = M_RUN;
          end else m_tmr++;
        end
        M_RST: if (m_tmr == RST_PULSE - 1) begin
                 m_st = M_RUN; m_tmr = 0;
                 if (!m_lock) m_rst_dis = 1;      // EN clears after the reset request
               end else m_tmr++;
      endcase
      if (m_rst_dis) begin m_en = 0; m_rst_dis = 0; end
      // configuration writes take effect after this edge
      if (wr_ok) begin
        case (a)
          12'h004: begin m_en = d[0]; m_bark_en = d[1]; m_rst_en = d[2]; m_pause = d[3]; if (d[31]) m_lock = 1; end
          12'h008: m_load = d;
          12'h00C: m_bark = d;
          default: ;
        endcase
      end
      // a read accepted now returns the register value after this edge
      if (dut.reg_re) begin
        case (dut.reg_raddr)
          12'h004: exp_rd.push_back({m_lock, 27'd0, m_pause, m_rst_en, m_bark_en, m_en});
          12'h008: exp_rd.push_back(m_load);
          12'h00C: exp_rd.push_back(m_bark);
          12'h010: exp_rd.push_back(m_count);
          12'h018: exp_rd.push_back({27'd0, m_st == M_LOG, m_bad, m_st == M_RST, m_bite_st, m_bark_st});
          12'h01C: exp_rd.push_back(m_rst_cnt);
          default: exp_rd.push_back('x);
        endcase
      end
    end
  end

  // error-log stand-in: acknowledges after a random delay or never
  int unsigned ack_dly = 1;
  bit          ack_never;
  always @(posedge clk_aon) begin
    static int unsigned c = 0;
    if (!wdt_evt) begin c = 0; wdt_ack <= 1'b0; end
    else begin
      c++;
      wdt_ack <= !ack_never && c >= ack_dly;
    end
  end

  // ---------------- stimulus ----------------
  typedef enum {K_CFG, K_KICK, K_BADKICK, K_WAIT, K_PWR, K_W1C, K_READ} kind_e;
  class wdt_op;
    rand kind_e kind;
    rand logic [31:0] load, bark;
    rand bit en, bark_en, rst_en, pause;
    rand int unsigned wait_n, adly;
    rand bit never;
    rand bit [1:0] ps;
    rand bit [3:0] w1c;
    constraint c_k   { kind dist {K_CFG := 2, K_KICK := 3, K_BADKICK := 1, K_WAIT := 4, K_PWR := 2, K_W1C := 2, K_READ := 3}; }
    constraint c_ld  { load inside {[8:300]}; bark dist {0 := 2, [1:150] := 3}; }
    constraint c_en  { en dist {1 := 4, 0 := 1}; }
    constraint c_w   { wait_n inside {[1:500]}; adly inside {[0:80]}; never dist {0 := 4, 1 := 1}; }
  endclass

  axil_master bfm;
  wdt_op      op;

  task automatic aon_wait(int unsigned n); repeat (n) @(posedge clk_aon); endtask

  // read and compare with the model value at the cycle the read was taken
  task automatic rd_cmp(logic [13:0] a, string what);
    logic [31:0] v, e;
    logic [1:0]  r;
    bfm.read(a, v, r);
    e = exp_rd.pop_front();
    check(r == 2'b00, {what, " read OKAY"});
    check_eq(v, e, what);
  endtask

  task automatic wr_exp(logic [13:0] a, logic [31:0] d, bit exp_err);
    logic [1:0] r;
    bfm.write(a, d, r);
    check(r == (exp_err ? 2'b10 : 2'b00), $sformatf("write 0x%03x response %0d (expected %s)", a, r,
                                                    exp_err ? "SLVERR" : "OKAY"));
  endtask

  task automatic do_op();
    if (op.randomize() == 0) $fatal(1, "wdt_op randomize failed");
    case (op.kind)
      K_CFG: begin
        wr_exp(R_LOAD, op.load, m_lock);
        wr_exp(R_BARK, op.bark, m_lock);
        wr_exp(R_CTRL, {28'd0, op.pause, op.rst_en, op.bark_en, op.en}, m_lock);
        ack_dly = op.adly; ack_never = op.never;
      end
      K_KICK:    wr_exp(R_KICK, WDT_KICK_KEY, 0);
      K_BADKICK: wr_exp(R_KICK, $urandom | 32'h1, 0);
      K_WAIT:    aon_wait(op.wait_n);
      K_PWR: begin
        @(negedge clk_aon) pwr_state = op.ps;
        aon_wait(op.wait_n);
        @(negedge clk_aon) pwr_state = PS_RUN;
      end
      K_W1C:  wr_exp(R_STATUS, 32'(op.w1c), 0);
      K_READ: begin
        rd_cmp(R_COUNT, "COUNT"); rd_cmp(R_STATUS, "STATUS"); rd_cmp(R_RST_CNT, "RST_CNT");
        rd_cmp(R_CTRL, "CTRL");
      end
    endcase
  endtask

  task automatic test_rand();
    int unsigned n_ops = 150;
    void'($value$plusargs("ops=%d", n_ops));
    repeat (n_ops) do_op();
  endtask

  task automatic test_lock();
    logic [31:0] v;
    wr_exp(R_LOAD, 100, 0);
    wr_exp(R_BARK, 20, 0);
    wr_exp(R_CTRL, 32'h8000_0007, 0);          // EN, BARK_EN, RST_EN, LOCK
    wr_exp(R_LOAD, 5, 1);
    wr_exp(R_BARK, 5, 1);
    wr_exp(R_CTRL, 32'h0, 1);                  // cannot disable or unlock
    rd_cmp(R_CTRL, "CTRL locked");
    repeat (5) begin aon_wait(50); wr_exp(R_KICK, WDT_KICK_KEY, 0); end
    rd_cmp(R_RST_CNT, "no reset while kicked");
    aon_wait(300);                             // let it bite
    rd_cmp(R_STATUS, "STATUS after bite");
    rd_cmp(R_RST_CNT, "RST_CNT after bite");
    check(m_rst_cnt >= 1, "locked watchdog still bites and requests a reset");
    repeat (60) do_op();
  endtask

  initial begin
    bfm = new(axi);
    op  = new();
    bfm.init();
    #(100ns);
    @(negedge clk_aon) rst_n = 1;
    aon_wait(5);
    begin
      logic [31:0] id;
      bfm.rd(14'h000, id);
      void'(exp_rd.pop_front());
      check_eq(id, 32'hDB60_0401, "ID");
    end
    case (test)
      "wdt_rand": test_rand();
      "wdt_lock": test_lock();
      default: $fatal(1, "unknown test %s", test);
    endcase
    $display("model: bites=%0d log_timeouts=%0d resets=%0d paused_cycles=%0d", n_bites, n_timeouts,
             n_resets, n_paused);
    report(test, seed);
    $finish;
  end

  initial begin
    int unsigned to = 40_000_000;
    void'($value$plusargs("timeout_ns=%d", to));
    #(to * 1ns);
    $display("TIMEOUT");
    check(0, "test did not finish before the timeout");
    report(test, seed);
    $fatal(1, "timeout");
  end

  // ---------------- SVA: specification rules ----------------
  default clocking cb @(posedge clk_aon); endclocking
  default disable iff (!rst_n);
  // the reset request is only raised after the bite was logged (ack) or the
  // log wait timed out
  a_log_first:  assert property ($rose(rst_req) |-> $past(wdt_evt) && ($past(wdt_ack) || $past(dut.tmr_q) == 8'(LOG_TIMEOUT - 1)));
  a_rst_pulse:  assert property ($rose(rst_req) |-> rst_req [*RST_PULSE] ##1 !rst_req);
  a_evt_hold:   assert property (wdt_evt && !wdt_ack && dut.tmr_q != 8'(LOG_TIMEOUT - 1) |=> wdt_evt);
  a_bite_at_0:  assert property ($rose(wdt_evt) |-> $past(dut.count_q) == 0 && $past(dut.en_q));
  a_no_rst_dis: assert property ($rose(rst_req) |-> $past(dut.rst_en_q));
  a_pause:      assert property (dut.en_q && dut.pause_lp_q && pwr_state inside {PS_SLEEP, PS_DSLEEP} &&
                                 !dut.kick && !dut.en_rise && dut.st_q == 2'd0 |=> dut.count_q == $past(dut.count_q));
  a_lock:       assert property (dut.lock_q |=> dut.lock_q);
  a_rst_stops:  assert property ($fell(rst_req) && !dut.lock_q |-> !dut.en_q);
  a_rst_locked: assert property ($fell(rst_req) && dut.lock_q |-> dut.en_q);
  a_lock_cfg:   assert property (dut.lock_q |=> $stable(dut.load_q) && $stable(dut.bark_q) && $stable(dut.en_q));
  c_rst_stop:   cover property ($fell(rst_req) && !dut.lock_q);
  a_irq:        assert property (irq == (dut.bark_st_q && dut.bark_en_q));
  c_bite_ack:   cover property (wdt_evt && wdt_ack);
  c_bite_to:    cover property (wdt_evt && dut.tmr_q == 8'(LOG_TIMEOUT - 1) && !wdt_ack);
  c_rst:        cover property ($rose(rst_req));
  c_bark:       cover property ($rose(irq));
  c_paused:     cover property (dut.en_q && dut.pause_lp_q && pwr_state == PS_SLEEP);
  c_bad_kick:   cover property ($rose(dut.bad_kick_q));
  c_lock:       cover property ($rose(dut.lock_q));
  c_kick_late:  cover property (dut.kick && dut.bark_st_q);
endmodule
