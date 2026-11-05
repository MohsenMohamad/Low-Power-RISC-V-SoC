// Class-based constrained-random testbench for dbg_errlog.
//
// Test errlog_rand: random sequence of exceptions and interrupts on the trap
// port (spaced, and back-to-back bursts that must produce EXC_OVR), PMU
// transition events with random results, watchdog log handshakes, watchdog
// reset pulses, software errors, W1C clears, KEEP_FIRST / IRQ_EN / FRZ_EN
// changes, and PD_CPU power-off periods (clk_cpu gated, inputs isolated).
// Registers and the irq_o / freeze_o pins are compared with a model; sticky
// status must survive the power-off periods.
`timescale 1ns/1ps
module tb_errlog;
  import dbg_pkg::*;
  import dbg_tb_pkg::*;

  logic clk_aon = 1'b0, clk_cpu_free = 1'b0, rst_n = 1'b0;
  logic cpu_clk_en = 1'b1, cpu_clk_en_l, clk_cpu;
  clk_cfg ccfg;
  int unsigned seed = 1;
  string test = "errlog_rand";

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("TEST=%s", test));
    ccfg = new();
    if (ccfg.randomize() == 0) $fatal(1, "clk_cfg randomize failed");
    $display("tb_errlog: test=%s seed=%0d aon_half=%0dps cpu_half=%0dps", test, seed,
             ccfg.aon_half_ps, ccfg.cpu_half_ps);
    fork
      forever #(ccfg.aon_half_ps * 1ps) clk_aon = ~clk_aon;
      begin #(ccfg.cpu_phase_ps * 1ps); forever #(ccfg.cpu_half_ps * 1ps) clk_cpu_free = ~clk_cpu_free; end
    join_none
  end
  always_latch if (!clk_cpu_free) cpu_clk_en_l = cpu_clk_en;
  assign clk_cpu = clk_cpu_free & cpu_clk_en_l;

  dbg_axil_if axi (.clk(clk_aon), .rst_n(rst_n));
  logic        trap_valid = 0;
  logic [31:0] trap_cause = 0, trap_pc = 0, trap_tval = 0;
  logic [1:0]  pwr_state = PS_RUN;
  logic        pmu_valid = 0;
  logic [1:0]  pmu_from = 0, pmu_to = 0, pmu_result = 0;
  logic        wdt_evt = 0, wdt_ack, wdt_rst = 0, irq, freeze;

  dbg_errlog dut (
    .clk_aon_i(clk_aon), .rst_aon_ni(rst_n), .clk_cpu_i(clk_cpu),
    .s_axil_awaddr(axi.awaddr[11:0]), .s_axil_awprot(axi.awprot), .s_axil_awvalid(axi.awvalid),
    .s_axil_awready(axi.awready), .s_axil_wdata(axi.wdata), .s_axil_wstrb(axi.wstrb),
    .s_axil_wvalid(axi.wvalid), .s_axil_wready(axi.wready), .s_axil_bresp(axi.bresp),
    .s_axil_bvalid(axi.bvalid), .s_axil_bready(axi.bready), .s_axil_araddr(axi.araddr[11:0]),
    .s_axil_arprot(axi.arprot), .s_axil_arvalid(axi.arvalid), .s_axil_arready(axi.arready),
    .s_axil_rdata(axi.rdata), .s_axil_rresp(axi.rresp), .s_axil_rvalid(axi.rvalid),
    .s_axil_rready(axi.rready),
    .trap_valid_i(trap_valid), .trap_cause_i(trap_cause), .trap_pc_i(trap_pc), .trap_tval_i(trap_tval),
    .pwr_state_i(pwr_state), .pmu_evt_valid_i(pmu_valid), .pmu_evt_from_i(pmu_from),
    .pmu_evt_to_i(pmu_to), .pmu_evt_result_i(pmu_result),
    .wdt_evt_i(wdt_evt), .wdt_evt_ack_o(wdt_ack), .wdt_rst_i(wdt_rst),
    .irq_o(irq), .freeze_o(freeze));

  dbg_axil_sva #(.AW(12)) u_axi_sva (
    .clk(clk_aon), .rst_n(rst_n),
    .awaddr(axi.awaddr[11:0]), .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wvalid(axi.wvalid), .wready(axi.wready),
    .bresp(axi.bresp), .bvalid(axi.bvalid), .bready(axi.bready),
    .araddr(axi.araddr[11:0]), .arvalid(axi.arvalid), .arready(axi.arready),
    .rdata(axi.rdata), .rresp(axi.rresp), .rvalid(axi.rvalid), .rready(axi.rready));

  localparam logic [13:0] R_STATUS = 14'h004, R_CTRL = 14'h008, R_IRQ_EN = 14'h00C, R_FRZ_EN = 14'h010,
                          R_SW_ERR = 14'h014, R_SW_CODE = 14'h018, R_EXC_CAUSE = 14'h020,
                          R_EXC_PC = 14'h024, R_EXC_TVAL = 14'h028, R_EXC_TS = 14'h02C,
                          R_EXC_CNT = 14'h030, R_PWR_LAST = 14'h040, R_PWR_TS = 14'h044,
                          R_PWR_ERR_LAST = 14'h048, R_WDT_CNT = 14'h050, R_WDT_TS = 14'h054,
                          R_WDT_PS = 14'h058, R_TSTAMP = 14'h05C;
  localparam int S_EXC = 0, S_OVR = 1, S_PWR = 2, S_BITE = 3, S_WRST = 4, S_SW = 5;

  // ---------------- model ----------------
  class errlog_model;
    bit [5:0]    status, irq_en, frz_en = 6'b011100;
    bit          keep_first;
    logic [31:0] cause, pc, tval, sw_code;
    int unsigned exc_cnt, wdt_cnt, pwr_cnt;
    logic [5:0]  pwr_last, pwr_err_last;
    logic [1:0]  wdt_ps;
    function void exception(logic [31:0] c, logic [31:0] p, logic [31:0] t);
      exc_cnt++;
      if (!(keep_first && status[S_EXC])) begin cause = c; pc = p; tval = t; end
      status[S_EXC] = 1;
    endfunction
  endclass

  // constrained-random operation mix
  typedef enum {OP_EXC, OP_BURST, OP_IRQ, OP_PMU, OP_WDT, OP_WRST, OP_SW, OP_W1C, OP_CFG, OP_OFF} op_e;
  class op_item;
    rand op_e         op;
    rand bit [4:0]    pc_k;
    rand bit [3:0]    code;
    rand bit [31:0]   tval;
    rand bit [1:0]    from, to, result;
    rand int unsigned burst_n, gap;
    rand bit [5:0]    mask;
    constraint c_op {
      op dist {OP_EXC := 5, OP_BURST := 2, OP_IRQ := 2, OP_PMU := 4, OP_WDT := 2, OP_WRST := 1,
               OP_SW := 1, OP_W1C := 3, OP_CFG := 2, OP_OFF := 2};
    }
    constraint c_code { code inside {[0:7], 11}; }
    constraint c_pmu  { from != to; result dist {0 := 3, [1:3] := 1}; }
    constraint c_b    { burst_n inside {[2:5]}; gap inside {[0:1]}; }
  endclass

  errlog_model m;
  axil_master  bfm;
  op_item      it;

  task automatic aon_wait(int unsigned n); repeat (n) @(posedge clk_aon); endtask
  task automatic cpu_quiet(int unsigned n);
    repeat (n) begin @(negedge clk_cpu_free); trap_valid = 0; @(posedge clk_cpu_free); end
  endtask
  task automatic settle(); cpu_quiet(8); aon_wait(8); cpu_quiet(4); endtask

  task automatic trap(logic [31:0] c, logic [31:0] p, logic [31:0] t);
    @(negedge clk_cpu);
    trap_valid = 1; trap_cause = c; trap_pc = p; trap_tval = t;
    @(negedge clk_cpu);
    trap_valid = 0;
  endtask

  task automatic check_all(string where);
    logic [31:0] v, tnow;
    settle();
    bfm.rd(R_TSTAMP, tnow);
    bfm.rd(R_STATUS, v);    check_eq(v, 32'(m.status), {where, ": STATUS"});
    bfm.rd(R_EXC_CNT, v);   check_eq(v, m.exc_cnt, {where, ": EXC_CNT"});
    if (m.exc_cnt != 0) begin
      bfm.rd(R_EXC_CAUSE, v); check_eq(v, m.cause, {where, ": EXC_CAUSE"});
      bfm.rd(R_EXC_PC, v);    check_eq(v, m.pc, {where, ": EXC_PC"});
      bfm.rd(R_EXC_TVAL, v);  check_eq(v, m.tval, {where, ": EXC_TVAL"});
      bfm.rd(R_EXC_TS, v);    check(v != 0 && v <= tnow, {where, ": EXC_TS in range"});
    end
    bfm.rd(R_PWR_LAST, v);  check_eq(v, {16'(m.pwr_cnt), 10'd0, m.pwr_last}, {where, ": PWR_LAST"});
    bfm.rd(R_PWR_ERR_LAST, v); check_eq(v, 32'(m.pwr_err_last), {where, ": PWR_ERR_LAST"});
    bfm.rd(R_WDT_CNT, v);   check_eq(v, m.wdt_cnt, {where, ": WDT_CNT"});
    if (m.wdt_cnt != 0) begin bfm.rd(R_WDT_PS, v); check_eq(v, 32'(m.wdt_ps), {where, ": WDT_PSTATE"}); end
    bfm.rd(R_SW_CODE, v);   check_eq(v, m.sw_code, {where, ": SW_CODE"});
    check(irq == |(m.status & m.irq_en), {where, ": irq_o"});
    check(freeze == |(m.status & m.frz_en), {where, ": freeze_o"});
  endtask

  task automatic do_op();
    if (it.randomize() == 0) $fatal(1, "op_item randomize failed");
    if ($test$plusargs("verbose")) $display("[%0t] op %s", $time, it.op.name());
    case (it.op)
      OP_EXC: begin
        logic [31:0] p = 32'h2000 + 32'(it.pc_k) * 4;
        trap(32'(it.code), p, it.tval);
        m.exception(32'(it.code), p, it.tval);
        settle();
      end
      OP_BURST: begin                       // back-to-back exceptions
        int unsigned cnt0 = m.exc_cnt;
        bit exc_was = m.status[S_EXC], ovr_was = m.status[S_OVR];
        logic [31:0] first_c = 32'(it.code), first_p = 32'h2000 + 32'(it.pc_k) * 4;
        logic [31:0] v, c;
        for (int unsigned i = 0; i < it.burst_n; i++) begin
          @(negedge clk_cpu);
          trap_valid = 1; trap_cause = (i == 0) ? first_c : 32'($urandom_range(0, 7));
          trap_pc = (i == 0) ? first_p : 32'h3000 + 32'(i) * 4; trap_tval = it.tval + i;
          @(negedge clk_cpu); trap_valid = 0;
          repeat (it.gap) @(negedge clk_cpu);
        end
        settle();
        // first one is always recorded; the others may be dropped (EXC_OVR)
        bfm.rd(R_EXC_CNT, v);
        check(v > cnt0 && v <= cnt0 + it.burst_n, "burst: EXC_CNT increment in [1, n]");
        bfm.rd(R_STATUS, c);
        check(c[S_OVR] == ((v < cnt0 + it.burst_n) || ovr_was), "burst: EXC_OVR set iff exceptions were dropped");
        if (!(m.keep_first && exc_was) && v == cnt0 + 1) begin
          logic [31:0] pcr;
          bfm.rd(R_EXC_PC, pcr); check_eq(pcr, first_p, "burst: first exception recorded");
        end
        // resynchronise the model with the observed outcome
        m.exc_cnt = v;
        m.status[S_EXC] = 1; m.status[S_OVR] = c[S_OVR];
        if (!(m.keep_first && exc_was)) begin
          bfm.rd(R_EXC_CAUSE, m.cause); bfm.rd(R_EXC_PC, m.pc); bfm.rd(R_EXC_TVAL, m.tval);
        end
      end
      OP_IRQ: begin                         // interrupts are not logged
        trap(32'h8000_0007, 32'h2000 + 32'(it.pc_k) * 4, 0);
        settle();
      end
      OP_PMU: begin
        @(negedge clk_aon);
        pmu_valid = 1; pmu_from = it.from; pmu_to = it.to; pmu_result = it.result;
        @(negedge clk_aon); pmu_valid = 0;
        m.pwr_cnt++;
        m.pwr_last = {it.result, it.to, it.from};
        if (it.result != 0) begin m.pwr_err_last = {it.result, it.to, it.from}; m.status[S_PWR] = 1; end
      end
      OP_WDT: begin                         // watchdog log handshake
        int unsigned n = 0;
        @(negedge clk_aon) wdt_evt = 1;
        while (!wdt_ack) begin @(negedge clk_aon); n++; end
        check(n == 1, "wdt_evt_ack_o one cycle after wdt_evt_i");
        wdt_evt = 0;
        m.wdt_cnt++; m.wdt_ps = pwr_state; m.status[S_BITE] = 1;
        aon_wait(2);
        check(!wdt_ack, "wdt_evt_ack_o drops after wdt_evt_i");
      end
      OP_WRST: begin
        @(negedge clk_aon) wdt_rst = 1; aon_wait(16); @(negedge clk_aon) wdt_rst = 0;
        m.status[S_WRST] = 1;
      end
      OP_SW: begin
        bfm.wr(R_SW_ERR, it.tval);
        m.sw_code = it.tval; m.status[S_SW] = 1;
      end
      OP_W1C: begin
        bfm.wr(R_STATUS, 32'(it.mask));
        m.status &= ~it.mask;
      end
      OP_CFG: begin
        bit kf = it.mask[0];
        bfm.wr(R_CTRL, 32'(kf)); m.keep_first = kf;
        bfm.wr(R_IRQ_EN, 32'(it.mask)); m.irq_en = it.mask;
        bfm.wr(R_FRZ_EN, 32'(~it.mask)); m.frz_en = ~it.mask;
      end
      OP_OFF: begin                         // PD_CPU off: gate, isolate, sleep
        @(negedge clk_cpu_free); cpu_clk_en = 0;
        trap_valid = 0; trap_cause = 0; trap_pc = 0; trap_tval = 0;
        @(negedge clk_aon) pwr_state = $urandom_range(0, 1) ? PS_SLEEP : PS_DSLEEP;
        aon_wait($urandom_range(20, 200));
        check_all("powered off");
        @(negedge clk_aon) pwr_state = PS_RUN;
        aon_wait(5);
        @(negedge clk_cpu_free); cpu_clk_en = 1;
      end
      default: ;
    endcase
  endtask

  initial begin
    int unsigned n_ops = 120;
    void'($value$plusargs("ops=%d", n_ops));
    bfm = new(axi);
    m   = new();
    it  = new();
    bfm.init();
    #(100ns);
    @(negedge clk_aon) rst_n = 1;
    aon_wait(5);
    begin
      logic [31:0] id;
      bfm.rd(14'h000, id);
      check_eq(id, 32'hDB60_0301, "ID");
    end
    check_all("reset");
    for (int i = 0; i < n_ops; i++) begin
      do_op();
      if (i % 10 == 9) check_all($sformatf("op %0d", i));
    end
    check_all("end");
    report(test, seed);
    $finish;
  end

  initial begin
    int unsigned to = 40_000_000;
    void'($value$plusargs("timeout_ns=%d", to));
    #(to * 1ns);
    $display("TIMEOUT");
    check(0, "test did not finish cnt0 the timeout");
    report(test, seed);
    $fatal(1, "timeout");
  end

  always @(posedge clk_aon) if ($test$plusargs("verbose") && rst_n) begin
    if (dut.drop_a != dut.drop_seen_q) $display("[%0t] drop_a %0d -> seen %0d (drop_c %0d)", $time, dut.drop_a, dut.drop_seen_q, dut.drop_c_q);
    if (dut.status_q != $past(dut.status_q)) $display("[%0t] status %02x", $time, dut.status_q);
  end
  // ---------------- white-box assertions and coverage ----------------
  default clocking cb @(posedge clk_aon); endclocking
  default disable iff (!rst_n);
  for (genvar i = 0; i < 6; i++) begin : g_sticky
    a_sticky: assert property (dut.status_q[i] && !(dut.reg_we && dut.reg_waddr == 12'h004 && dut.reg_wdata[i])
                               |=> dut.status_q[i]);
    c_set: cover property (!dut.status_q[i] ##1 dut.status_q[i]);
    c_clr: cover property (dut.status_q[i] ##1 !dut.status_q[i]);
  end
  a_ack:      assert property (wdt_evt && !dut.wdt_logged_q |=> wdt_ack);
  a_pwr_err:  assert property (pmu_valid && pmu_result != 0 |=> dut.status_q[2]);
  a_irq:      assert property (irq == |(dut.status_q & dut.irq_en_q));
  a_freeze:   assert property (freeze == |(dut.status_q & dut.frz_en_q));
  a_held:     assert property (@(posedge clk_cpu) disable iff (!rst_n)
                               dut.busy_c |=> $stable(dut.h_cause_q) && $stable(dut.h_pc_q) && $stable(dut.h_tval_q));
  c_ovr:        cover property (dut.drop_a != dut.drop_seen_q);
  c_keep_first: cover property (dut.new_exc && dut.keep_first_q && dut.status_q[0]);
  c_res1:       cover property (pmu_valid && pmu_result == 2'd1);
  c_res2:       cover property (pmu_valid && pmu_result == 2'd2);
  c_res3:       cover property (pmu_valid && pmu_result == 2'd3);
  c_irq:        cover property (!irq ##1 irq);
  c_freeze:     cover property (!freeze ##1 freeze);
endmodule
