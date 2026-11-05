// Class-based constrained-random testbench for dbg_trace.
//
// Tests (+TEST=<name>):
//   trace_rand    random trigger / freeze / log configurations, random retire
//                 and trap streams, power-state changes (with clk_cpu gating),
//                 freeze_i pulses, clears; buffer compared to a reference model
//   trace_pwroff  capture, then PD_CPU off (clk_cpu gated, inputs isolated to
//                 0, state SLEEP / DEEP_SLEEP): whole buffer read back and
//                 compared; capture resumes after wake
//
// Control actions (configuration, enable, clear, freeze, power changes) are
// applied in quiet windows with no CPU activity, long enough for the
// clock-domain crossings to settle, so the reference model is exact.
`timescale 1ns/1ps
module tb_trace;
  import dbg_pkg::*;
  import dbg_tb_pkg::*;

  localparam int unsigned DEPTH = 32;

  // ---------------- clocks / reset ----------------
  logic clk_aon = 1'b0, clk_cpu_free = 1'b0, rst_n = 1'b0;
  logic cpu_clk_en = 1'b1, cpu_clk_en_l;
  logic clk_cpu;
  clk_cfg ccfg;
  int unsigned seed = 1;
  string test = "trace_rand";

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("TEST=%s", test));
    ccfg = new();
    if (ccfg.randomize() == 0) $fatal(1, "clk_cfg randomize failed");
    $display("tb_trace: test=%s seed=%0d aon_half=%0dps cpu_half=%0dps phase=%0dps",
             test, seed, ccfg.aon_half_ps, ccfg.cpu_half_ps, ccfg.cpu_phase_ps);
    fork
      forever #(ccfg.aon_half_ps * 1ps) clk_aon = ~clk_aon;
      begin
        #(ccfg.cpu_phase_ps * 1ps);
        forever #(ccfg.cpu_half_ps * 1ps) clk_cpu_free = ~clk_cpu_free;
      end
    join_none
  end
  // latch-based clock gate (glitch free), as the SoC clock gate wrapper
  always_latch if (!clk_cpu_free) cpu_clk_en_l = cpu_clk_en;
  assign clk_cpu = clk_cpu_free & cpu_clk_en_l;

  // ---------------- DUT ----------------
  dbg_axil_if axi (.clk(clk_aon), .rst_n(rst_n));
  logic        ret_valid = 0, trap_valid = 0, freeze_in = 0;
  logic [31:0] ret_pc = 0, ret_insn = 0, trap_cause = 0, trap_pc = 0, trap_tval = 0;
  logic [1:0]  pwr_state = PS_RUN;

  dbg_trace #(.DEPTH(DEPTH)) dut (
    .clk_aon_i(clk_aon), .rst_aon_ni(rst_n), .clk_cpu_i(clk_cpu),
    .s_axil_awaddr(axi.awaddr[11:0]), .s_axil_awprot(axi.awprot), .s_axil_awvalid(axi.awvalid),
    .s_axil_awready(axi.awready), .s_axil_wdata(axi.wdata), .s_axil_wstrb(axi.wstrb),
    .s_axil_wvalid(axi.wvalid), .s_axil_wready(axi.wready), .s_axil_bresp(axi.bresp),
    .s_axil_bvalid(axi.bvalid), .s_axil_bready(axi.bready), .s_axil_araddr(axi.araddr[11:0]),
    .s_axil_arprot(axi.arprot), .s_axil_arvalid(axi.arvalid), .s_axil_arready(axi.arready),
    .s_axil_rdata(axi.rdata), .s_axil_rresp(axi.rresp), .s_axil_rvalid(axi.rvalid),
    .s_axil_rready(axi.rready),
    .ret_valid_i(ret_valid), .ret_pc_i(ret_pc), .ret_insn_i(ret_insn),
    .trap_valid_i(trap_valid), .trap_cause_i(trap_cause), .trap_pc_i(trap_pc), .trap_tval_i(trap_tval),
    .pwr_state_i(pwr_state), .freeze_i(freeze_in));

  dbg_axil_sva #(.AW(12)) u_axi_sva (
    .clk(clk_aon), .rst_n(rst_n),
    .awaddr(axi.awaddr[11:0]), .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wvalid(axi.wvalid), .wready(axi.wready),
    .bresp(axi.bresp), .bvalid(axi.bvalid), .bready(axi.bready),
    .araddr(axi.araddr[11:0]), .arvalid(axi.arvalid), .arready(axi.arready),
    .rdata(axi.rdata), .rresp(axi.rresp), .rvalid(axi.rvalid), .rready(axi.rready));

  // ---------------- registers ----------------
  localparam logic [13:0] R_CTRL = 14'h004, R_STATUS = 14'h008, R_TRIG = 14'h00C, R_START = 14'h010,
                          R_STOP = 14'h014, R_MASK = 14'h018, R_WPTR = 14'h01C, R_COUNT = 14'h020,
                          R_DEPTH = 14'h024, R_TOTAL = 14'h028, R_TSTAMP = 14'h02C;

  // ---------------- configuration (randomised) ----------------
  class trace_cfg;
    rand bit [1:0]  start_sel, stop_sel;
    rand bit [4:0]  start_k, stop_k;
    rand bit [31:0] mask;
    rand bit        log_trap, log_pwr, frz_exc, frz_err;
    constraint c_mask { mask dist {32'hFFFF_FFFF := 6, 32'hFFFF_FF8F := 2, 32'hFFFF_FFF0 := 1}; }
    constraint c_stop { stop_sel dist {TRIG_NONE := 4, TRIG_PC := 3, TRIG_EXC := 2, TRIG_PWR := 2}; }
    constraint c_frz  { frz_exc dist {1'b0 := 3, 1'b1 := 1}; }
    function logic [31:0] start_pc(); return 32'h1000 + 32'(start_k) * 4; endfunction
    function logic [31:0] stop_pc();  return 32'h1000 + 32'(stop_k) * 4;  endfunction
    function logic [31:0] ctrl(bit en, bit clr, bit frz);
      return {25'd0, frz_err, frz_exc, log_pwr, log_trap, frz, clr, en};
    endfunction
  endclass

  // ---------------- CPU stimulus: constrained-random bursts ----------------
  // One randomize() call produces NB cycles (the constraint solver is
  // called per burst, not per cycle).
  localparam int unsigned NB = 32;
  class cpu_burst;
    rand bit        ret[NB], trap[NB], is_irq[NB];
    rand bit [4:0]  pc_k[NB], tpc_k[NB];
    rand bit [3:0]  exc_code[NB];
    int unsigned    ret_pct = 60, trap_pct = 3;
    bit             first_no_ret = 0;    // previous burst ended with a trap
    constraint c_rate {
      foreach (ret[i]) {
        ret[i]  dist {1'b1 := ret_pct, 1'b0 := 100 - ret_pct};
        trap[i] dist {1'b1 := trap_pct, 1'b0 := 100 - trap_pct};
        exc_code[i] inside {[0:7], 11};
        is_irq[i] dist {1'b0 := 3, 1'b1 := 1};
      }
    }
    // pipeline flush: no retire in the cycle after a trap
    constraint c_flush {
      foreach (ret[i]) if (i > 0) trap[i-1] -> !ret[i];
      first_no_ret -> !ret[0];
    }
    function logic [31:0] cause(int i);
      if (is_irq[i]) return exc_code[i][0] ? 32'h8000_0007 : 32'h8000_000B;
      return 32'(exc_code[i]);
    endfunction
  endclass

  // ---------------- reference model ----------------
  typedef struct { logic [31:0] pc, data, info; } ent_t;
  class trace_model;
    typedef enum {M_IDLE, M_ARMED, M_ACTIVE, M_STOPPED} mst_t;
    mst_t        st = M_IDLE;
    bit          en, frozen;
    trace_cfg    cfg;
    ent_t        ents[$];
    int unsigned total;
    // coverage-style statistics
    int unsigned n_start[4], n_stop[4], n_frz_exc, n_frz_err, n_frz_sw, n_pwr_ent, n_both;

    function new(trace_cfg c); cfg = c; endfunction

    function bit pc_hit(logic [31:0] pc, logic [31:0] r);
      return ((pc ^ r) & cfg.mask) == 0;
    endfunction
    function bit hit(bit [1:0] sel, logic [31:0] r, bit ret, logic [31:0] pc, bit exc, bit pwr);
      case (sel)
        TRIG_PC:  return ret && pc_hit(pc, r);
        TRIG_EXC: return exc;
        TRIG_PWR: return pwr;
        default:  return 0;
      endcase
    endfunction
    function void push(ent_t e);
      ents.push_back(e); total++;
      if (ents.size() > DEPTH) void'(ents.pop_front());
    endfunction

    // one clk_cpu cycle as sampled by the DUT
    function void cycle(bit ret, logic [31:0] pc, logic [31:0] insn,
                        bit trap, logic [31:0] cause, logic [31:0] tpc, logic [31:0] tval,
                        bit pwr, bit [1:0] pstate);
      bit exc = trap && !cause[31];
      bit sh, eh, cap;
      if (!en) return;
      sh  = (cfg.start_sel == TRIG_NONE) || hit(cfg.start_sel, cfg.start_pc(), ret, pc, exc, pwr);
      eh  = hit(cfg.stop_sel, cfg.stop_pc(), ret, pc, exc, pwr);
      cap = !frozen && (st == M_ACTIVE || (st == M_ARMED && sh));
      if (cap) begin
        if (ret) push('{pc: pc, data: insn, info: {30'd0, TE_RETIRE}});
        if (trap && cfg.log_trap)
          push('{pc: tpc, data: tval, info: {cause[31], 7'd0, cause[7:0], 12'd0, 2'b00, TE_TRAP}});
        if (pwr && cfg.log_pwr) begin
          push('{pc: 0, data: 0, info: {28'd0, pstate, TE_PWR}});
          n_pwr_ent++;
        end
        if (ret && trap) n_both++;
      end
      if (!frozen) begin
        if (st == M_ARMED && sh) begin
          n_start[cfg.start_sel]++;
          st = eh ? M_STOPPED : M_ACTIVE;
          if (eh) n_stop[cfg.stop_sel]++;
        end else if (st == M_ACTIVE && eh) begin
          st = M_STOPPED;
          n_stop[cfg.stop_sel]++;
        end
      end
      if (exc && cfg.frz_exc && !frozen) begin frozen = 1; n_frz_exc++; end
    endfunction

    // START_SEL=none: ARMED -> ACTIVE on the next clk_cpu edge, even without
    // CPU activity (the control path always settles with clk_cpu running).
    function void auto_start();
      if (en && st == M_ARMED && !frozen && cfg.start_sel == TRIG_NONE) begin
        st = M_ACTIVE; n_start[0]++;
      end
    endfunction
    function void clear();
      ents.delete(); total = 0; frozen = 0;
      st = en ? M_ARMED : M_IDLE;
      auto_start();
    endfunction
    function void set_en(bit e);
      en = e;
      st = e ? (st == M_IDLE ? M_ARMED : st) : M_IDLE;
      auto_start();
    endfunction
  endclass

  trace_cfg   cfg;
  trace_model mdl;
  axil_master bfm;
  cpu_burst   stim;
  bit         clk_gated;
  bit         pwr_pending;     // power change not yet seen by clk_cpu

  // ---------------- CPU-side driver ----------------
  task automatic cpu_quiet(int unsigned n);
    repeat (n) begin
      @(negedge clk_cpu_free);
      ret_valid = 0; trap_valid = 0;
      @(posedge clk_cpu_free);
    end
  endtask

  // Run n clk_cpu cycles of random activity; the model follows each edge.
  task automatic cpu_run(int unsigned n);
    bit last_trap = 0;
    int unsigned i = NB;
    repeat (n) begin
      @(negedge clk_cpu);
      if (i == NB) begin
        stim.first_no_ret = last_trap;
        if (stim.randomize() == 0) $fatal(1, "cpu_burst randomize failed");
        i = 0;
      end
      ret_valid  = stim.ret[i];
      ret_pc     = 32'h1000 + 32'(stim.pc_k[i]) * 4;
      ret_insn   = $urandom;
      trap_valid = stim.trap[i];
      trap_cause = stim.cause(i);
      trap_pc    = 32'h1000 + 32'(stim.tpc_k[i]) * 4;
      trap_tval  = $urandom;
      last_trap  = stim.trap[i];
      i++;
      @(posedge clk_cpu);
      mdl.cycle(ret_valid, ret_pc, ret_insn, trap_valid, trap_cause, trap_pc, trap_tval, 1'b0, 2'b00);
    end
    @(negedge clk_cpu);
    ret_valid = 0; trap_valid = 0;
  endtask

  task automatic aon_wait(int unsigned n);
    repeat (n) @(posedge clk_aon);
  endtask

  // Let all crossings settle (clk_cpu running).
  task automatic settle();
    cpu_quiet(6);
    aon_wait(6);
    cpu_quiet(4);
  endtask

  // Power-state change. With gate=1 clk_cpu is stopped (and inputs isolated)
  // while the state is not RUN; the DUT then sees one coalesced event when
  // the clock resumes.
  task automatic set_power(bit [1:0] ps, bit gate);
    bit changed;
    // the PMU gates clk_cpu before leaving RUN and ungates it last on wake
    if (gate && ps != PS_RUN && !clk_gated) begin
      @(negedge clk_cpu_free); cpu_clk_en = 0; clk_gated = 1;
    end
    aon_wait(5);
    changed = (ps != pwr_state);
    @(negedge clk_aon) pwr_state = ps;
    aon_wait(5);
    if (changed) pwr_pending = 1;
    if (clk_gated && ps == PS_RUN) begin
      @(negedge clk_cpu_free); cpu_clk_en = 1; clk_gated = 0;
    end
    if (!clk_gated && pwr_pending) begin
      // one (possibly coalesced) event, seen by clk_cpu in a quiet cycle
      settle();
      mdl.cycle(0, 0, 0, 0, 0, 0, 0, 1'b1, pwr_state);
      pwr_pending = 0;
    end
  endtask

  task automatic write_cfg();
    bfm.wr(R_TRIG,  {26'd0, cfg.stop_sel, 2'd0, cfg.start_sel});
    bfm.wr(R_START, cfg.start_pc());
    bfm.wr(R_STOP,  cfg.stop_pc());
    bfm.wr(R_MASK,  cfg.mask);
  endtask

  task automatic set_ctrl(bit en, bit clr, bit frz);
    bfm.wr(R_CTRL, cfg.ctrl(en, clr, frz));
    if (clr) mdl.clear();
    mdl.set_en(en);
    if (frz && !mdl.frozen) begin mdl.frozen = 1; mdl.n_frz_sw++; end
    settle();
  endtask

  // ---------------- readout and compare ----------------
  task automatic compare(string where);
    logic [31:0] status, wptr, count, total, depth, tnow, w0, w1, w2, w3, last_ts;
    int unsigned n, oldest, base;
    settle();
    aon_wait(4);
    bfm.rd(R_STATUS, status);
    bfm.rd(R_WPTR, wptr);
    bfm.rd(R_COUNT, count);
    bfm.rd(R_TOTAL, total);
    bfm.rd(R_DEPTH, depth);
    bfm.rd(R_TSTAMP, tnow);
    check_eq(depth, DEPTH, {where, ": DEPTH"});
    check_eq(total, mdl.total, {where, ": TOTAL"});
    n = mdl.total < DEPTH ? mdl.total : DEPTH;
    check_eq(count, n, {where, ": COUNT"});
    check_eq(wptr, mdl.total % DEPTH, {where, ": WPTR"});
    check(status[1] == mdl.frozen, $sformatf("%s: STATUS.FROZEN=%0d model=%0d", where, status[1], mdl.frozen));
    check(status[2] == (mdl.total >= DEPTH), {where, ": STATUS.WRAPPED"});
    check(status[0] == (mdl.st == trace_model::M_ACTIVE), $sformatf("%s: STATUS.ACTIVE=%0d model st=%s", where, status[0], mdl.st.name()));
    check(status[3] == (mdl.st == trace_model::M_STOPPED), $sformatf("%s: STATUS.STOPPED=%0d model st=%s", where, status[3], mdl.st.name()));
    check(status[4] == (mdl.st == trace_model::M_ARMED), $sformatf("%s: STATUS.ARMED=%0d model st=%s", where, status[4], mdl.st.name()));
    check(status[6] == 0, {where, ": STATUS.OVF"});
    oldest = (mdl.total >= DEPTH) ? wptr : 0;
    base   = mdl.ents.size() - n;
    last_ts = 0;
    for (int unsigned k = 0; k < n; k++) begin
      int unsigned idx = (oldest + k) % DEPTH;
      logic [13:0] a = 14'h800 + 14'(idx * 16);
      bfm.rd(a + 0, w0); bfm.rd(a + 4, w1); bfm.rd(a + 8, w2); bfm.rd(a + 12, w3);
      check_eq(w0, mdl.ents[base + k].pc,   $sformatf("%s: entry %0d PC", where, k));
      check_eq(w1, mdl.ents[base + k].data, $sformatf("%s: entry %0d DATA", where, k));
      check_eq(w3, mdl.ents[base + k].info, $sformatf("%s: entry %0d INFO", where, k));
      check(w2 >= last_ts && w2 <= tnow, $sformatf("%s: entry %0d TS 0x%08x not in [0x%08x, 0x%08x]",
                                                   where, k, w2, last_ts, tnow));
      last_ts = w2;
    end
  endtask

  // ---------------- tests ----------------
  task automatic randomize_cfg();
    if (cfg.randomize() == 0) $fatal(1, "trace_cfg randomize failed");
  endtask

  task automatic test_rand();
    int unsigned phases = 12;
    void'($value$plusargs("phases=%d", phases));
    for (int unsigned ph = 0; ph < phases; ph++) begin
      logic [1:0] resp;
      // disable, reconfigure, optionally clear, enable
      set_ctrl(0, 0, 0);
      randomize_cfg();
      write_cfg();
      set_ctrl(1, ($urandom_range(0, 2) != 0), 0);
      // config writes are refused while enabled
      bfm.write(R_TRIG, 32'h33, resp);
      check(resp == 2'b10, "TRIG write while EN=1 must return SLVERR");
      repeat ($urandom_range(2, 6)) begin
        randcase
          6: cpu_run($urandom_range(5, 60));
          2: set_power(2'($urandom_range(0, 3)), 1'b0);
          2: begin                                // sleep with clock gated, wake
               set_power(2'($urandom_range(1, 3)), 1'b1);
               aon_wait($urandom_range(5, 40));
               if ($urandom_range(0, 1)) set_power(2'($urandom_range(1, 3)), 1'b1);
               set_power(PS_RUN, 1'b1);
             end
          1: begin                                // error freeze request
               @(negedge clk_aon) freeze_in = 1; settle();
               if (cfg.frz_err && !mdl.frozen) begin mdl.frozen = 1; mdl.n_frz_err++; end
               @(negedge clk_aon) freeze_in = 0; settle();
             end
          1: set_ctrl(1, 0, 1);                    // software freeze
        endcase
      end
      if ($urandom_range(0, 1)) set_ctrl(0, 0, 0);
      compare($sformatf("phase %0d", ph));
    end
  endtask

  task automatic test_pwroff();
    logic [31:0] st;
    cfg.start_sel = TRIG_NONE; cfg.stop_sel = TRIG_NONE; cfg.mask = '1;
    cfg.log_trap = 1; cfg.log_pwr = 1; cfg.frz_exc = 0; cfg.frz_err = 1;
    write_cfg();
    set_ctrl(1, 1, 0);
    while (mdl.total < DEPTH + DEPTH / 4) cpu_run(16);
    // PD_CPU off: clock gated, isolation clamps the inputs to 0
    set_power($urandom_range(0, 1) ? PS_SLEEP : PS_DSLEEP, 1'b1);
    ret_valid = 0; trap_valid = 0; ret_pc = 0; ret_insn = 0;
    aon_wait(20);
    // read the whole buffer while PD_CPU is off (aon-only reads)
    begin
      logic [31:0] w0, w1, w3;
      int unsigned base = mdl.ents.size() - DEPTH;
      bfm.rd(R_STATUS, st);
      check(st[2], "pwroff: WRAPPED");
      for (int unsigned k = 0; k < DEPTH; k++) begin
        int unsigned idx = (mdl.total + k) % DEPTH;
        logic [13:0] a = 14'h800 + 14'(idx * 16);
        bfm.rd(a, w0); bfm.rd(a + 4, w1); bfm.rd(a + 12, w3);
        check_eq(w0, mdl.ents[base + k].pc,   $sformatf("pwroff: entry %0d PC", k));
        check_eq(w1, mdl.ents[base + k].data, $sformatf("pwroff: entry %0d DATA", k));
        check_eq(w3, mdl.ents[base + k].info, $sformatf("pwroff: entry %0d INFO", k));
      end
    end
    set_power(PS_RUN, 1'b1);
    cpu_run(20);
    compare("after wake");
  endtask

  // ---------------- main ----------------
  initial begin
    bfm  = new(axi);
    cfg  = new();
    mdl  = new(cfg);
    stim = new();
    bfm.init();
    #(100ns);
    @(negedge clk_aon) rst_n = 1;
    aon_wait(5);
    cpu_quiet(5);
    begin
      logic [31:0] id;
      bfm.rd(14'h000, id);
      check_eq(id, 32'hDB60_0101, "ID");
    end
    case (test)
      "trace_rand":   test_rand();
      "trace_pwroff": test_pwroff();
      default: $fatal(1, "unknown test %s", test);
    endcase
    $display("model: starts none/pc/exc/pwr=%0d/%0d/%0d/%0d stops=%0d/%0d/%0d/%0d frz exc/err/sw=%0d/%0d/%0d pwr_entries=%0d ret+trap=%0d",
             mdl.n_start[0], mdl.n_start[1], mdl.n_start[2], mdl.n_start[3],
             mdl.n_stop[0], mdl.n_stop[1], mdl.n_stop[2], mdl.n_stop[3],
             mdl.n_frz_exc, mdl.n_frz_err, mdl.n_frz_sw, mdl.n_pwr_ent, mdl.n_both);
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
endmodule
