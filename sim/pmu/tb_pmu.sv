// -----------------------------------------------------------------------------
// tb_pmu - PMU unit testbench (class-based, constrained random, SVA)
//
// Runs on Verilator --timing (needs constraint solving: Verilator >= 5.028,
// see README) with the PMU's own SVA enabled (SVA_ON).
//
// Structure
//   pmu_if          signal bundle (clocking via plain posedge sampling)
//   pmu_episode     randomized low-power episode (mode, DVFS target, wake
//                   source, wake mask, masked-out pending interrupt ("noise"),
//                   abort / dirty-cache error injection, delays)
//   pmu_delay       randomized response delay of an environment block
//   pmu_env         reactive models of the blocks around the PMU: clock gate,
//                   power switch, CPU reset, DVFS clock mux, bus
//   pmu_core        CPU core model: WFI, idle_req/idle_ack handshake, abort,
//                   power loss / reboot, isolation clamping
//   pmu_ref         reference model: expected STATUS / SLEEP_CNT / IDLE_CNT /
//                   WAKE_CAUSE / CUR_OP / VSEL / RAM retention per episode
//   pmu_cov         functional coverage (FSM arcs, DVFS pairs, mode x wake
//                   source, error injection); pass requires full coverage
//   pmu_test        drives N episodes through register writes, checks, reports
// Plusargs: +episodes=<n> +seed=<n> (seed is applied with Verilator +verilator+seed)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

interface pmu_if (input logic clk);
  logic        rst_n;
  // register port
  logic        req, we;
  logic [11:0] addr;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        ack, err;
  logic [31:0] rdata;
  // wake sources
  logic        meip, mtip, msip;
  // core / environment
  logic        core_sleep, idle_ack, cache_clean, idle_req;
  logic        cg_en, cg_ack, bus_idle;
  logic        iso_en, cpu_rst_n, cpu_rst_ack, pwr_sw_en, pwr_good, ram_ret;
  logic [1:0]  dvfs_sel, vsel;
  logic [2:0]  dvfs_active;
  logic        irq;
  logic [4:0]  state;
endinterface

package pmu_tb_pkg;
  // register offsets
  localparam logic [11:0] R_CTRL = 12'h00, R_STATUS = 12'h04, R_DVFS = 12'h08, R_IRQ_EN = 12'h0C,
                          R_WAKE = 12'h18, R_SLEEP_CNT = 12'h1C, R_VSEL = 12'h20,
                          R_WAKE_MASK = 12'h24, R_IDLE_CNT = 12'h28;
  localparam int ST_RUN = 0, ST_IDLE_REQ = 1, ST_IDLE = 3, ST_VUP = 4, ST_SWITCH = 5, ST_VDN = 6,
                 ST_OFF = 10;
  localparam int NARC = 24;
  // FSM arcs {from, to}; must match rtl/aon/pmu.sv
  localparam logic [9:0] ARCS [NARC] = '{
    {5'd0, 5'd1}, {5'd1, 5'd2}, {5'd1, 5'd18}, {5'd2, 5'd3}, {5'd2, 5'd7},
    {5'd3, 5'd4}, {5'd3, 5'd17}, {5'd4, 5'd5}, {5'd5, 5'd6}, {5'd6, 5'd3},
    {5'd7, 5'd8}, {5'd7, 5'd3}, {5'd8, 5'd9}, {5'd9, 5'd10}, {5'd10, 5'd11},
    {5'd10, 5'd12}, {5'd11, 5'd12}, {5'd12, 5'd13}, {5'd13, 5'd14}, {5'd14, 5'd15},
    {5'd15, 5'd16}, {5'd16, 5'd17}, {5'd17, 5'd18}, {5'd18, 5'd0}};

  // ---------------------------------------------------------------------------
  class pmu_episode;
    rand bit [1:0]    mode;        // 0 IDLE, 1 SLEEP, 2 DEEP_SLEEP
    rand bit          do_dvfs;
    rand bit [1:0]    target;
    rand bit [1:0]    wake_src;    // 0 meip, 1 mtip, 2 msip
    rand bit [2:0]    wake_mask;   // WAKE_MASK = the core's mie wake sources
    rand bit          noise;       // a source outside the mask is pending while low power
    rand bit [1:0]    noise_src;
    rand int unsigned noise_len;   // cycles the masked source alone is pending
    rand bit          abort;       // interrupt arrives together with WFI
    rand bit          dirty;       // core reports dirty D-cache
    rand int unsigned wake_delay;  // cycles in low power before the wake event
    rand int unsigned ack_delay;   // core idle_ack latency
    rand int unsigned bus_busy;    // cycles the bus stays busy in BUS_DRAIN

    constraint c_legal  { mode inside {[0:2]}; target inside {[0:2]}; wake_src inside {[0:2]};
                          noise_src inside {[0:2]}; }
    // The wake source is in the mask (= mie), the noise source is not.
    // (Written as constant bit selects: Verilator 5.054's solver does not
    // honour a variable bit select in a constraint; the episode is re-checked
    // after randomize() in run().)
    constraint c_mask   { (wake_src == 0) -> wake_mask[0]; (wake_src == 1) -> wake_mask[1];
                          (wake_src == 2) -> wake_mask[2]; }
    constraint c_noise  { noise dist {1'b0 := 1, 1'b1 := 1};
                          (noise && noise_src == 0) -> !wake_mask[0];
                          (noise && noise_src == 1) -> !wake_mask[1];
                          (noise && noise_src == 2) -> !wake_mask[2];
                          noise -> !abort;
                          noise_len inside {[20:60]}; }
    constraint c_inject { abort dist {1'b0 := 9, 1'b1 := 1};
                          dirty dist {1'b0 := 8, 1'b1 := 2};
                          abort -> !dirty; }
    constraint c_delays { wake_delay inside {[0:40]}; ack_delay inside {[1:6]}; bus_busy inside {[0:6]}; }

    function string sprint();
      return $sformatf("mode=%0d dvfs=%0d tgt=%0d wake=%0d mask=%b noise=%0d/%0d abort=%0d dirty=%0d wd=%0d",
                       mode, do_dvfs, target, wake_src, wake_mask, noise, noise_src, abort, dirty, wake_delay);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_delay;
    rand int unsigned d;
    int unsigned lo, hi;
    constraint c_range { d >= lo; d <= hi; }
    function new(int unsigned lo_i, int unsigned hi_i);
      lo = lo_i;
      hi = hi_i;
    endfunction
    function int unsigned next();
      if (randomize() != 1) $fatal(1, "pmu_delay randomize failed");
      return d;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Environment: everything the PMU controls answers with random latency.
  class pmu_env;
    virtual pmu_if vif;
    pmu_delay dly_cg, dly_psw, dly_rst, dly_mux;
    int unsigned bus_busy;

    function new(virtual pmu_if v);
      vif     = v;
      dly_cg  = new(1, 4);
      dly_psw = new(1, 8);
      dly_rst = new(1, 3);
      dly_mux = new(1, 6);
    endfunction

    task automatic follow_cg();
      forever begin
        @(posedge vif.clk);
        if (vif.cg_ack != vif.cg_en) begin
          automatic logic tgt = vif.cg_en;
          repeat (dly_cg.next()) @(posedge vif.clk);
          vif.cg_ack <= tgt;
        end
      end
    endtask

    task automatic follow_psw();
      forever begin
        @(posedge vif.clk);
        if (vif.pwr_good != vif.pwr_sw_en) begin
          automatic logic tgt = vif.pwr_sw_en;
          repeat (dly_psw.next()) @(posedge vif.clk);
          vif.pwr_good <= tgt;
        end
      end
    endtask

    task automatic follow_rst();
      forever begin
        @(posedge vif.clk);
        if (vif.cpu_rst_ack != vif.cpu_rst_n) begin
          automatic logic tgt = vif.cpu_rst_n;
          repeat (dly_rst.next()) @(posedge vif.clk);
          vif.cpu_rst_ack <= tgt;
        end
      end
    endtask

    // Glitch-free mux: old branch stops, gap, new branch starts.
    task automatic follow_mux();
      forever begin
        @(posedge vif.clk);
        if (vif.dvfs_active != (3'b001 << vif.dvfs_sel)) begin
          automatic logic [1:0] tgt = vif.dvfs_sel;
          repeat (dly_mux.next()) @(posedge vif.clk);
          vif.dvfs_active <= 3'b000;
          repeat (dly_mux.next()) @(posedge vif.clk);
          vif.dvfs_active <= 3'b001 << tgt;
        end
      end
    endtask

    // The bus is busy for bus_busy cycles whenever the PMU starts draining.
    task automatic model_bus();
      forever begin
        @(posedge vif.clk);
        if (vif.state == 5'd2 && vif.cg_ack == 1'b0 && bus_busy > 0) begin
          vif.bus_idle <= 1'b0;
          repeat (bus_busy) @(posedge vif.clk);
          vif.bus_idle <= 1'b1;
        end
      end
    endtask

    task automatic run();
      fork
        follow_cg();
        follow_psw();
        follow_rst();
        follow_mux();
        model_bus();
      join_none
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // CPU core model (outputs pass through the isolation clamp).
  class pmu_core;
    virtual pmu_if vif;
    bit          in_wfi, ack, dirty;
    bit          req_seen;            // idle_req as seen through the synchronizer
    int unsigned ack_delay = 2;
    bit [2:0]    mie = 3'b111;        // {msip, mtip, meip} enables

    function new(virtual pmu_if v);
      vif = v;
    endfunction

    // RISC-V WFI: ends on an interrupt that is pending and enabled in mie
    function bit irq_any();
      return |({vif.msip, vif.mtip, vif.meip} & mie);
    endfunction

    task automatic run();
      bit req_q1;
      forever begin
        @(posedge vif.clk);
        req_seen = req_q1;
        req_q1   = vif.idle_req;
        if (!vif.cpu_rst_ack || !vif.pwr_good) begin
          // reset / unpowered: state lost
          in_wfi = 1'b0;
          ack    = 1'b0;
        end else begin
          // leave WFI on interrupt once the PMU has withdrawn idle_req
          if (in_wfi && irq_any() && !req_seen && !ack) in_wfi = 1'b0;
          if (req_seen && in_wfi && !ack) begin
            repeat (ack_delay - 1) @(posedge vif.clk);
            if (vif.idle_req && in_wfi) ack = 1'b1;
          end
          if (!req_seen && ack) ack = 1'b0;
        end
        vif.core_sleep  <= vif.iso_en ? 1'b0 : in_wfi;
        vif.idle_ack    <= vif.iso_en ? 1'b0 : ack;
        vif.cache_clean <= vif.iso_en ? 1'b0 : !dirty;
      end
    endtask

    function void execute_wfi();
      in_wfi = 1'b1;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Reference model of the architecturally visible PMU state.
  class pmu_ref;
    int unsigned sleep_cnt;
    int unsigned idle_cnt;
    bit [1:0]    cur_op = 2'd2;
    bit [1:0]    target = 2'd2;
    bit [2:0]    wake_cause;
    // per-episode expectations
    bit exp_resume, exp_resume_deep, exp_dvfs_done, exp_err_dirty, exp_ret;

    function void predict(pmu_episode ep);
      bit powered, idled;
      if (ep.do_dvfs) target = ep.target;
      powered         = !ep.abort && ep.mode != 2'd0 && !ep.dirty;
      idled           = !ep.abort && (ep.mode == 2'd0 || ep.dirty);
      exp_resume      = powered;
      exp_resume_deep = powered && ep.mode == 2'd2;
      exp_err_dirty   = !ep.abort && ep.mode != 2'd0 && ep.dirty;
      exp_ret         = powered && ep.mode == 2'd2;
      exp_dvfs_done   = idled && (target != cur_op);
      if (exp_dvfs_done) cur_op = target;
      if (powered) sleep_cnt++;
      if (!ep.abort && ep.mode == 2'd0) idle_cnt++;   // CLK_GATE -> IDLE (a refusal goes BUS_DRAIN -> IDLE)
      if (!ep.abort) wake_cause = (3'b001 << ep.wake_src) | (ep.noise ? (3'b001 << ep.noise_src) : 3'b000);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_cov;
    int arc_hits [NARC];
    int op_hits [3][3];
    int mode_wake [3][3];
    int dirty_hits [3];
    int masked_hold [3];               // masked pending source held, per mode
    int abort_hits, wake_in_dvfs, illegal;

    function void sample_state(logic [4:0] prev, logic [4:0] cur);
      bit found = 0;
      if (prev == cur) return;
      foreach (ARCS[a]) if (ARCS[a] == {prev, cur}) begin arc_hits[a]++; found = 1; end
      if (!found) begin
        illegal++;
        $error("illegal PMU transition %0d -> %0d", prev, cur);
      end
    endfunction

    function void sample_episode(pmu_episode ep);
      if (ep.abort) abort_hits++;
      else begin
        mode_wake[ep.mode][ep.wake_src]++;
        if (ep.dirty) dirty_hits[ep.mode]++;
        if (ep.noise) masked_hold[ep.mode]++;
      end
    endfunction

    function int report();
      int holes = 0;
      $display("== PMU unit coverage ==");
      foreach (arc_hits[a]) begin
        $display("  arc %2d -> %2d : %0d%s", ARCS[a][9:5], ARCS[a][4:0], arc_hits[a],
                 arc_hits[a] == 0 ? "  MISSING" : "");
        if (arc_hits[a] == 0) holes++;
      end
      for (int f = 0; f < 3; f++)
        for (int t = 0; t < 3; t++)
          if (f != t) begin
            $display("  DVFS OP%0d -> OP%0d : %0d%s", f, t, op_hits[f][t], op_hits[f][t] == 0 ? "  MISSING" : "");
            if (op_hits[f][t] == 0) holes++;
          end
      for (int m = 0; m < 3; m++)
        for (int w = 0; w < 3; w++) begin
          $display("  mode %0d x wake %s : %0d%s", m, w == 0 ? "meip" : w == 1 ? "mtip" : "msip",
                   mode_wake[m][w], mode_wake[m][w] == 0 ? "  MISSING" : "");
          if (mode_wake[m][w] == 0) holes++;
        end
      for (int m = 1; m < 3; m++) begin
        $display("  dirty cache refused, mode %0d : %0d%s", m, dirty_hits[m], dirty_hits[m] == 0 ? "  MISSING" : "");
        if (dirty_hits[m] == 0) holes++;
      end
      for (int m = 0; m < 3; m++) begin
        $display("  masked pending interrupt does not wake, mode %0d : %0d%s", m, masked_hold[m],
                 masked_hold[m] == 0 ? "  MISSING" : "");
        if (masked_hold[m] == 0) holes++;
      end
      $display("  WFI abort : %0d%s", abort_hits, abort_hits == 0 ? "  MISSING" : "");
      $display("  wake during DVFS : %0d%s", wake_in_dvfs, wake_in_dvfs == 0 ? "  MISSING" : "");
      if (abort_hits == 0) holes++;
      if (wake_in_dvfs == 0) holes++;
      $display("  coverage holes: %0d, illegal transitions: %0d", holes, illegal);
      return holes + illegal;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_test;
    virtual pmu_if vif;
    pmu_env  env;
    pmu_core core;
    pmu_ref  rm;
    pmu_cov  cov;
    int      errors;
    bit      ret_seen;

    function new(virtual pmu_if v);
      vif  = v;
      env  = new(v);
      core = new(v);
      rm   = new();
      cov  = new();
    endfunction

    task automatic write(logic [11:0] a, logic [31:0] d);
      @(posedge vif.clk);
      vif.req   <= 1'b1;
      vif.we    <= 1'b1;
      vif.addr  <= a;
      vif.wdata <= d;
      vif.wstrb <= 4'hF;
      @(posedge vif.clk);
      vif.req <= 1'b0;
      vif.we  <= 1'b0;
    endtask

    task automatic read(logic [11:0] a, output logic [31:0] d);
      @(posedge vif.clk);
      vif.req  <= 1'b1;
      vif.we   <= 1'b0;
      vif.addr <= a;
      @(negedge vif.clk);
      d = vif.rdata;
      @(posedge vif.clk);
      vif.req <= 1'b0;
    endtask

    function void check(bit cond, string what);
      if (!cond) begin
        errors++;
        $error("CHECK FAILED: %s", what);
      end
    endfunction

    task automatic set_wake(int src, bit v);
      case (src)
        0: vif.meip <= v;
        1: vif.mtip <= v;
        default: vif.msip <= v;
      endcase
    endtask

    task automatic wait_state_in(int s0, int s1, int s2, int s3, int s4, int timeout);
      int n = 0;
      while (!(vif.state inside {s0, s1, s2, s3, s4})) begin
        @(posedge vif.clk);
        if (++n > timeout) begin
          errors++;
          $error("timeout waiting for PMU state (in %0d)", vif.state);
          return;
        end
      end
    endtask

    // Monitors: FSM arcs, DVFS pairs, RAM retention.
    task automatic monitor();
      logic [4:0] prev = 5'd0;
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n) begin
          cov.sample_state(prev, vif.state);
          if (vif.ram_ret) ret_seen = 1'b1;
        end
        prev = vif.state;
      end
    endtask

    task automatic episode(pmu_episode ep);
      logic [31:0] st, v;
      bit [1:0] op_before = rm.cur_op;
      ret_seen = 1'b0;
      core.ack_delay = ep.ack_delay;
      core.dirty     = ep.dirty;
      env.bus_busy   = ep.bus_busy;

      // firmware: program and execute WFI (mie and WAKE_MASK hold the same set)
      core.mie = ep.wake_mask;
      write(R_WAKE_MASK, {29'b0, ep.wake_mask});
      write(R_CTRL, {23'b0, 1'b1, 6'b0, ep.mode});
      if (ep.do_dvfs) write(R_DVFS, {30'b0, ep.target});
      write(R_IRQ_EN, 32'h1);
      rm.predict(ep);
      @(posedge vif.clk);
      core.execute_wfi();

      if (ep.abort) begin
        @(posedge vif.clk);
        set_wake(ep.wake_src, 1'b1);              // interrupt races the WFI
      end else begin
        wait_state_in(ST_IDLE, ST_OFF, ST_VUP, ST_SWITCH, ST_VDN, 2000);
        if (ep.noise) begin
          // a pending interrupt outside the mask (and mie): no wake
          wait_state_in(ST_IDLE, ST_OFF, ST_OFF, ST_OFF, ST_OFF, 2000);
          set_wake(ep.noise_src, 1'b1);
          for (int i = 0; i < ep.noise_len; i++) begin
            @(posedge vif.clk);
            check(vif.state inside {ST_IDLE, ST_OFF, ST_VUP, ST_SWITCH, ST_VDN},
                  $sformatf("masked source woke the PMU: state %0d (%s)", vif.state, ep.sprint()));
          end
        end
        repeat (ep.wake_delay) @(posedge vif.clk);
        if (vif.state inside {ST_VUP, ST_SWITCH, ST_VDN}) cov.wake_in_dvfs++;
        set_wake(ep.wake_src, 1'b1);
      end
      // back to RUN with the core executing again
      wait_state_in(ST_RUN, ST_RUN, ST_RUN, ST_RUN, ST_RUN, 4000);
      while (core.in_wfi) @(posedge vif.clk);
      repeat (3) @(posedge vif.clk);
      if (vif.state != ST_RUN) wait_state_in(ST_RUN, ST_RUN, ST_RUN, ST_RUN, ST_RUN, 4000);
      set_wake(ep.wake_src, 1'b0);                // firmware clears the source
      if (ep.noise) set_wake(ep.noise_src, 1'b0);
      core.dirty = 1'b0;

      // checks against the reference model
      read(R_STATUS, st);
      check(st[16] == rm.exp_resume,      $sformatf("RESUME %0d (%s)", st[16], ep.sprint()));
      check(st[17] == rm.exp_resume_deep, $sformatf("RESUME_DEEP %0d (%s)", st[17], ep.sprint()));
      check(st[18] == rm.exp_dvfs_done,   $sformatf("DVFS_DONE %0d (%s)", st[18], ep.sprint()));
      check(st[19] == rm.exp_err_dirty,   $sformatf("ERR_DIRTY %0d (%s)", st[19], ep.sprint()));
      check(st[9:8] == rm.cur_op,         $sformatf("CUR_OP %0d exp %0d", st[9:8], rm.cur_op));
      check(st[10] == (rm.target != rm.cur_op), "DVFS_PEND");
      check(vif.irq == rm.exp_dvfs_done,  "irq");
      read(R_SLEEP_CNT, v);
      check(v == rm.sleep_cnt, $sformatf("SLEEP_CNT %0d exp %0d", v, rm.sleep_cnt));
      read(R_WAKE, v);
      check(v[2:0] == rm.wake_cause, $sformatf("WAKE_CAUSE %b exp %b (%s)", v[2:0], rm.wake_cause, ep.sprint()));
      read(R_VSEL, v);
      check(v[1:0] == rm.cur_op, "VSEL");
      read(R_IDLE_CNT, v);
      check(v == rm.idle_cnt, $sformatf("IDLE_CNT %0d exp %0d (%s)", v, rm.idle_cnt, ep.sprint()));
      read(R_WAKE_MASK, v);
      check(v[2:0] == ep.wake_mask, "WAKE_MASK readback");
      check(vif.dvfs_sel == rm.cur_op, "dvfs_sel");
      check(ret_seen == rm.exp_ret, $sformatf("RAM retention seen %0d (%s)", ret_seen, ep.sprint()));
      if (rm.exp_dvfs_done) cov.op_hits[op_before][rm.cur_op]++;
      cov.sample_episode(ep);
      write(R_STATUS, 32'h000F_0000);             // W1C all flags
    endtask

    task automatic run(int n_episodes);
      pmu_episode ep = new();
      env.run();
      fork
        core.run();
        monitor();
      join_none
      for (int i = 0; i < n_episodes; i++) begin
        if (ep.randomize() != 1) $fatal(1, "episode randomize failed");
        if (!ep.wake_mask[ep.wake_src] || (ep.noise && ep.wake_mask[ep.noise_src]))
          $fatal(1, "episode constraints violated: %s", ep.sprint());
        if ($test$plusargs("verbose")) $display("[tb_pmu] episode %0d: %s", i, ep.sprint());
        episode(ep);
      end
    endtask
  endclass
endpackage

// -----------------------------------------------------------------------------
module tb_pmu;
  import pmu_tb_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  pmu_if vif (clk);

  pmu #(
    .NUM_OP (3), .RESET_OP (2'd2), .VSETTLE_CYCLES (4), .RET_CYCLES (3),
    .ISO_CYCLES (2), .RST_CLK_CYCLES (3)
  ) dut (
    .clk_i (clk), .rst_ni (vif.rst_n),
    .req_i (vif.req), .we_i (vif.we), .addr_i (vif.addr), .wdata_i (vif.wdata), .wstrb_i (vif.wstrb),
    .ack_o (vif.ack), .rdata_o (vif.rdata), .err_o (vif.err),
    .meip_i (vif.meip), .mtip_i (vif.mtip), .msip_i (vif.msip),
    .core_sleep_i (vif.core_sleep), .idle_ack_i (vif.idle_ack), .cache_clean_i (vif.cache_clean),
    .idle_req_o (vif.idle_req), .cg_en_o (vif.cg_en), .cg_ack_i (vif.cg_ack), .bus_idle_i (vif.bus_idle),
    .iso_en_o (vif.iso_en), .cpu_rst_no (vif.cpu_rst_n), .cpu_rst_ack_i (vif.cpu_rst_ack),
    .pwr_sw_en_o (vif.pwr_sw_en), .pwr_good_i (vif.pwr_good), .ram_ret_o (vif.ram_ret),
    .dvfs_sel_o (vif.dvfs_sel), .dvfs_active_i (vif.dvfs_active), .vsel_o (vif.vsel),
    .irq_o (vif.irq), .state_o (vif.state)
  );

  // ---------------- testbench-level SVA ----------------
  // The environment protocol as the PMU sees it.
  a_ack_needs_req: assert property (@(posedge clk) disable iff (!vif.rst_n)
    $rose(vif.idle_ack) |-> $past(vif.idle_req)) else $error("idle_ack without idle_req");
  // Voltage never below the frequency actually running in the mux.
  a_vsel_vs_mux: assert property (@(posedge clk) disable iff (!vif.rst_n)
    vif.dvfs_active != 3'b000 |-> (vif.dvfs_active & ~((3'b010 << vif.vsel) - 3'b001)) == 3'b000)
    else $error("clock faster than voltage allows");
  // Power is never cut while the bus is busy or the core is not isolated.
  a_off_idle_bus: assert property (@(posedge clk) disable iff (!vif.rst_n)
    $fell(vif.pwr_sw_en) |-> vif.iso_en && !vif.cg_en) else $error("unsafe power-off");
  // Power-state transitions (cover properties)
  c_run_idle:  cover property (@(posedge clk) vif.state == 5'd3  && $past(vif.state) == 5'd2);
  c_run_sleep: cover property (@(posedge clk) vif.state == 5'd10 && !vif.ram_ret);
  c_run_deep:  cover property (@(posedge clk) vif.state == 5'd10 && vif.ram_ret);
  c_dvfs_up:   cover property (@(posedge clk) $changed(vif.dvfs_sel) && vif.dvfs_sel > $past(vif.dvfs_sel));
  c_dvfs_down: cover property (@(posedge clk) $changed(vif.dvfs_sel) && vif.dvfs_sel < $past(vif.dvfs_sel));
  c_abort:     cover property (@(posedge clk) vif.state == 5'd18 && $past(vif.state) == 5'd1);
  c_dirty:     cover property (@(posedge clk) vif.state == 5'd3  && $past(vif.state) == 5'd7);

  initial begin
    pmu_test test;
    int n_ep, fails;
    if (!$value$plusargs("episodes=%d", n_ep)) n_ep = 400;
    vif.rst_n = 1'b0;
    vif.req = 0; vif.we = 0; vif.addr = 0; vif.wdata = 0; vif.wstrb = 0;
    vif.meip = 0; vif.mtip = 0; vif.msip = 0;
    vif.core_sleep = 0; vif.idle_ack = 0; vif.cache_clean = 1;
    vif.cg_ack = 1; vif.bus_idle = 1; vif.cpu_rst_ack = 1; vif.pwr_good = 1;
    vif.dvfs_active = 3'b100;
    repeat (5) @(posedge clk);
    vif.rst_n = 1'b1;
    test = new(vif);
    test.run(n_ep);
    fails = test.cov.report();
    if (test.errors == 0 && fails == 0) $display("[tb_pmu] TEST PASSED (%0d episodes)", n_ep);
    else $fatal(1, "[tb_pmu] TEST FAILED: %0d check errors, %0d coverage holes/illegal arcs",
                test.errors, fails);
    $finish;
  end

  initial begin
    #50ms;
    $fatal(1, "[tb_pmu] global timeout");
  end
endmodule
