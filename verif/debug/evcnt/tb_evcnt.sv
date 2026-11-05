// Class-based constrained-random testbench for dbg_evcnt.
//
// Tests (+TEST=<name>):
//   evcnt_rand  random I$/D$/stall event bursts, power-state and DVFS changes,
//               freeze (register and freeze_i), clear; all counters compared
//               with a reference model while frozen; 64-bit coherent reads
//   evcnt_pwr   power states with clk_cpu gated (IDLE / SLEEP / DEEP_SLEEP):
//               time-in-state and wake counts exact, CPU counters readable
//               and stable while PD_CPU is off
//
// The AON-domain model is cycle exact (it follows the decoded register
// writes of the DUT's AXI front end). CPU-domain counters are compared after
// quiet windows, because freeze / clear reach clk_cpu through synchronisers.
`timescale 1ns/1ps
module tb_evcnt;
  import dbg_pkg::*;
  import dbg_tb_pkg::*;

  logic clk_aon = 1'b0, clk_cpu_free = 1'b0, rst_n = 1'b0;
  logic cpu_clk_en = 1'b1, cpu_clk_en_l, clk_cpu;
  clk_cfg ccfg;
  int unsigned seed = 1;
  string test = "evcnt_rand";

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("TEST=%s", test));
    ccfg = new();
    if (ccfg.randomize() == 0) $fatal(1, "clk_cfg randomize failed");
    $display("tb_evcnt: test=%s seed=%0d aon_half=%0dps cpu_half=%0dps", test, seed,
             ccfg.aon_half_ps, ccfg.cpu_half_ps);
    fork
      forever #(ccfg.aon_half_ps * 1ps) clk_aon = ~clk_aon;
      begin #(ccfg.cpu_phase_ps * 1ps); forever #(ccfg.cpu_half_ps * 1ps) clk_cpu_free = ~clk_cpu_free; end
    join_none
  end
  always_latch if (!clk_cpu_free) cpu_clk_en_l = cpu_clk_en;
  assign clk_cpu = clk_cpu_free & cpu_clk_en_l;

  dbg_axil_if axi (.clk(clk_aon), .rst_n(rst_n));
  logic [4:0] ev = '0;           // {stall, dc_miss, dc_hit, ic_miss, ic_hit}
  logic [1:0] pwr_state = PS_RUN, dvfs_op = 2'd0;
  logic       freeze_in = 1'b0;

  dbg_evcnt dut (
    .clk_aon_i(clk_aon), .rst_aon_ni(rst_n), .clk_cpu_i(clk_cpu),
    .s_axil_awaddr(axi.awaddr[11:0]), .s_axil_awprot(axi.awprot), .s_axil_awvalid(axi.awvalid),
    .s_axil_awready(axi.awready), .s_axil_wdata(axi.wdata), .s_axil_wstrb(axi.wstrb),
    .s_axil_wvalid(axi.wvalid), .s_axil_wready(axi.wready), .s_axil_bresp(axi.bresp),
    .s_axil_bvalid(axi.bvalid), .s_axil_bready(axi.bready), .s_axil_araddr(axi.araddr[11:0]),
    .s_axil_arprot(axi.arprot), .s_axil_arvalid(axi.arvalid), .s_axil_arready(axi.arready),
    .s_axil_rdata(axi.rdata), .s_axil_rresp(axi.rresp), .s_axil_rvalid(axi.rvalid),
    .s_axil_rready(axi.rready),
    .ic_hit_i(ev[0]), .ic_miss_i(ev[1]), .dc_hit_i(ev[2]), .dc_miss_i(ev[3]), .stall_i(ev[4]),
    .pwr_state_i(pwr_state), .dvfs_op_i(dvfs_op), .freeze_i(freeze_in));

  dbg_axil_sva #(.AW(12)) u_axi_sva (
    .clk(clk_aon), .rst_n(rst_n),
    .awaddr(axi.awaddr[11:0]), .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wvalid(axi.wvalid), .wready(axi.wready),
    .bresp(axi.bresp), .bvalid(axi.bvalid), .bready(axi.bready),
    .araddr(axi.araddr[11:0]), .arvalid(axi.arvalid), .arready(axi.arready),
    .rdata(axi.rdata), .rresp(axi.rresp), .rvalid(axi.rvalid), .rready(axi.rready));

  localparam logic [13:0] R_CTRL = 14'h004, R_STATUS = 14'h008, R_CNT0 = 14'h010, R_WAKE = 14'h024,
                          R_DVFS = 14'h028, R_TRANS = 14'h02C, R_T0 = 14'h030, R_PSTATE = 14'h050;

  // ---------------- reference model ----------------
  // AON part: cycle exact, follows register writes as decoded by the DUT.
  longint unsigned m_t[4];
  int unsigned     m_wake, m_dvfs, m_trans;
  bit              m_frz, m_frz_err;
  logic [1:0]      m_ps = PS_RUN, m_op = 2'd0;
  always @(posedge clk_aon) begin
    if (rst_n) begin
      automatic bit frozen = m_frz || (m_frz_err && freeze_in);
      automatic bit we_ctrl = dut.reg_we && dut.reg_waddr == 12'h004;
      if (we_ctrl && dut.reg_wdata[1]) begin
        m_t = '{0, 0, 0, 0}; m_wake = 0; m_dvfs = 0; m_trans = 0;
      end else if (!frozen) begin
        m_t[m_ps]++;
        if (pwr_state != m_ps) begin
          m_trans++;
          if (pwr_state == PS_RUN && (m_ps == PS_SLEEP || m_ps == PS_DSLEEP)) m_wake++;
        end
        if (dvfs_op != m_op) m_dvfs++;
      end
      m_ps = pwr_state;
      m_op = dvfs_op;
      if (we_ctrl) begin m_frz = dut.reg_wdata[0]; m_frz_err = dut.reg_wdata[2]; end
    end
  end
  // CPU part
  int unsigned m_cnt[5];
  bit          m_cpu_frozen;

  // ---------------- constrained-random event bursts ----------------
  localparam int unsigned NB = 32;
  class ev_burst;
    rand bit [4:0] e[NB];
    rand int unsigned hit_pct;
    constraint c_pct { hit_pct inside {[50:95]}; }
    constraint c_ev {
      foreach (e[i]) {
        // a lookup is either a hit or a miss, never both
        !(e[i][0] && e[i][1]);
        !(e[i][2] && e[i][3]);
        e[i][0] dist {1'b1 := hit_pct, 1'b0 := 100 - hit_pct};
        e[i][4] dist {1'b1 := 1, 1'b0 := 3};
      }
    }
  endclass

  axil_master bfm;
  ev_burst    eb;
  bit         clk_gated;

  task automatic aon_wait(int unsigned n); repeat (n) @(posedge clk_aon); endtask
  task automatic cpu_quiet(int unsigned n);
    repeat (n) begin @(negedge clk_cpu_free); ev = '0; @(posedge clk_cpu_free); end
  endtask
  task automatic settle(); cpu_quiet(6); aon_wait(6); cpu_quiet(4); endtask

  task automatic cpu_run(int unsigned n);
    int unsigned i = NB;
    repeat (n) begin
      @(negedge clk_cpu);
      if (i == NB) begin
        if (eb.randomize() == 0) $fatal(1, "ev_burst randomize failed");
        i = 0;
      end
      ev = eb.e[i++];
      @(posedge clk_cpu);
      if (!m_cpu_frozen) for (int k = 0; k < 5; k++) m_cnt[k] += 32'(ev[k]);
    end
    @(negedge clk_cpu); ev = '0;
  endtask

  task automatic write_ctrl(bit frz, bit clr, bit frz_err);
    bfm.wr(R_CTRL, {29'd0, frz_err, clr, frz});
    if (clr) m_cnt = '{0, 0, 0, 0, 0};
    settle();
  endtask

  task automatic set_power(logic [1:0] ps);
    if (ps != PS_RUN && !clk_gated) begin @(negedge clk_cpu_free); cpu_clk_en = 0; clk_gated = 1; end
    aon_wait(5);
    @(negedge clk_aon) pwr_state = ps;
    aon_wait($urandom_range(5, 60));
    if (ps == PS_RUN && clk_gated) begin @(negedge clk_cpu_free); cpu_clk_en = 1; clk_gated = 0; end
  endtask

  task automatic set_dvfs(logic [1:0] op);
    aon_wait(5); @(negedge clk_aon) dvfs_op = op; aon_wait(5);
  endtask

  // Compare everything while frozen (values static).
  task automatic compare(string where);
    logic [31:0] v, lo, hi, st;
    bit was_frozen = m_frz;
    if (!was_frozen) begin
      bfm.wr(R_CTRL, {29'd0, m_frz_err, 1'b0, 1'b1});
      m_cpu_frozen = 1;
      settle();
    end
    for (int k = 0; k < 5; k++) begin
      bfm.rd(R_CNT0 + 14'(4 * k), v);
      check_eq(v, m_cnt[k], $sformatf("%s: CPU counter %0d", where, k));
    end
    bfm.rd(R_WAKE, v);  check_eq(v, m_wake, {where, ": WAKE_CNT"});
    bfm.rd(R_DVFS, v);  check_eq(v, m_dvfs, {where, ": DVFS_CNT"});
    bfm.rd(R_TRANS, v); check_eq(v, m_trans, {where, ": TRANS_CNT"});
    for (int k = 0; k < 4; k++) begin
      bfm.rd(R_T0 + 14'(8 * k), lo);
      bfm.rd(R_T0 + 14'(8 * k) + 4, hi);
      check_eq(lo, m_t[k][31:0], $sformatf("%s: T[%0d] LO", where, k));
      check_eq(hi, m_t[k][63:32], $sformatf("%s: T[%0d] HI", where, k));
    end
    bfm.rd(R_PSTATE, v); check_eq(v, {26'd0, dvfs_op, 2'd0, pwr_state}, {where, ": PSTATE"});
    bfm.rd(R_STATUS, st);
    check(st[0] == 1'b1, {where, ": STATUS.FROZEN"});
    check(st[1] == 1'b0, {where, ": STATUS.CLR_PEND"});
    if (!was_frozen) begin
      bfm.wr(R_CTRL, {29'd0, m_frz_err, 1'b0, 1'b0});
      m_cpu_frozen = 0;
      settle();
    end
  endtask

  // Live 64-bit read: LO then HI must be one coherent, increasing value.
  task automatic live_read();
    logic [31:0] lo, hi;
    longint unsigned prev = 0, cur;
    for (int k = 0; k < 4; k++) begin
      bfm.rd(R_T0 + 14'(8 * pwr_state), lo);
      bfm.rd(R_T0 + 14'(8 * pwr_state) + 4, hi);
      cur = {hi, lo};
      check(cur >= prev, "live 64-bit read is monotonic");
      prev = cur;
    end
  endtask

  task automatic test_rand();
    int unsigned phases = 10;
    void'($value$plusargs("phases=%d", phases));
    write_ctrl(0, 1, 0);
    for (int unsigned ph = 0; ph < phases; ph++) begin
      repeat ($urandom_range(3, 8)) begin
        randcase
          6: cpu_run($urandom_range(10, 120));
          2: begin set_power(2'($urandom_range(1, 3))); set_power(PS_RUN); end
          1: begin set_power(PS_IDLE); cpu_quiet(2); set_power(PS_RUN); end
          2: set_dvfs(2'($urandom_range(0, 2)));
          1: begin                                     // freeze by freeze_i
               bit fe = $urandom_range(0, 1);
               write_ctrl(0, 0, fe);
               @(negedge clk_aon) freeze_in = 1; m_cpu_frozen = fe; settle();
               cpu_run(20);
               aon_wait($urandom_range(1, 30));
               @(negedge clk_aon) freeze_in = 0; m_cpu_frozen = 0; settle();
             end
          1: begin                                     // register freeze
               write_ctrl(1, 0, m_frz_err); m_cpu_frozen = 1;
               cpu_run(20); set_power(PS_IDLE); set_power(PS_RUN);
               write_ctrl(0, 0, m_frz_err); m_cpu_frozen = 0;
             end
          1: write_ctrl(0, 1, m_frz_err);             // clear
          1: live_read();
        endcase
      end
      compare($sformatf("phase %0d", ph));
    end
  endtask

  task automatic test_pwr();
    write_ctrl(0, 1, 0);
    for (int i = 0; i < 12; i++) begin
      logic [31:0] a, b;
      cpu_run($urandom_range(20, 80));
      set_power(2'($urandom_range(1, 3)));
      // PD_CPU off / gated: CPU counters readable and stable
      bfm.rd(R_CNT0, a);
      aon_wait(40);
      bfm.rd(R_CNT0, b);
      check_eq(b, a, "CPU counter stable while clk_cpu is gated");
      check_eq(a, m_cnt[0], "CPU counter readable while clk_cpu is gated");
      if ($urandom_range(0, 2) == 0) set_dvfs(2'($urandom_range(0, 2)));   // DVFS while idle
      set_power(PS_RUN);
      compare($sformatf("cycle %0d", i));
    end
  endtask

  initial begin
    bfm = new(axi);
    eb  = new();
    bfm.init();
    #(100ns);
    @(negedge clk_aon) rst_n = 1;
    aon_wait(5);
    begin
      logic [31:0] id;
      bfm.rd(14'h000, id);
      check_eq(id, 32'hDB60_0201, "ID");
    end
    case (test)
      "evcnt_rand": test_rand();
      "evcnt_pwr":  test_pwr();
      default: $fatal(1, "unknown test %s", test);
    endcase
    $display("model: wake=%0d dvfs=%0d trans=%0d t_run=%0d t_idle=%0d t_sleep=%0d t_dsleep=%0d",
             m_wake, m_dvfs, m_trans, m_t[0], m_t[1], m_t[2], m_t[3]);
    report(test, seed);
    $finish;
  end

  initial begin
    int unsigned to = 20_000_000;
    void'($value$plusargs("timeout_ns=%d", to));
    #(to * 1ns);
    $display("TIMEOUT");
    check(0, "test did not finish before the timeout");
    report(test, seed);
    $fatal(1, "timeout");
  end

  // ---------------- cover properties ----------------
  default clocking cb @(posedge clk_aon); endclocking
  c_wake_sleep:  cover property (pwr_state == PS_SLEEP ##1 pwr_state == PS_RUN);
  c_wake_dsleep: cover property (pwr_state == PS_DSLEEP ##1 pwr_state == PS_RUN);
  c_idle:        cover property (pwr_state == PS_RUN ##1 pwr_state == PS_IDLE);
  c_dvfs_chg:    cover property (dvfs_op != $past(dvfs_op));
  c_frz_err:     cover property (dut.frz_err_q && freeze_in);
  c_clear_pend:  cover property (dut.clr_pend);
  c_ovf:         cover property (dut.ovf_q != 0);
  // white-box: frozen counters hold
  a_frozen_hold: assert property (disable iff (!rst_n) dut.frozen && !(dut.do_clr) |=> dut.t_q[0] == $past(dut.t_q[0]));
endmodule
