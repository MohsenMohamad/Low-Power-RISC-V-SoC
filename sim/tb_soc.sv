// -----------------------------------------------------------------------------
// tb_soc - SoC-level testbench (Verilator and Icarus Verilog)
//
// * Runs the boot-ROM firmware (default build/fw/pm_test.hex) and decodes the
//   UART; the firmware prints "PASS" or "FAIL <n>".
// * Drives four mutually asynchronous clocks (clk_aon + three DVFS clocks).
// * External wake pin: pulsed when the PMU has been in OFF for EXT_WAKE_DELAY
//   clk_aon cycles (the firmware uses it for the ext-wake tests).
// * OFF-state corruption model (generated from the netlist): when the PD_CPU
//   supply goes down every PD_CPU state element is overwritten and every PD_CPU
//   output is forced to the corruption value; at power-up the state is
//   corrupted again (random power-up state). CORRUPT_X selects X (4-state
//   simulators), otherwise random values are used (Verilator).
// * Checks: no X / unknowns on the AON side and on valid-qualified isolated
//   PD_CPU outputs, isolation whenever the supply is off, no RAM access in
//   retention, plus all RTL SVA (Verilator, SVA_ON).
// * Power-state transition coverage: PMU FSM arcs, architectural power-state
//   transitions and DVFS operating-point transitions; written to COV_FILE.
// Plusargs: +vcd  +timeout=<ns>  +break_iso (negative test: defeat isolation)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`define PD_CPU_PATH tb_soc.dut.u_pd_cpu
`ifdef CORRUPT_X
  `define PD_CPU_CORRUPT(lhs, width) lhs <= 'x;
  `define PD_CPU_CORRUPT_BLK(lhs, width) lhs = 'x;
  `define PD_CPU_FORCE(lhs, width)   force lhs = 'x;
`else
  `define PD_CPU_CORRUPT(lhs, width) lhs <= width'({$urandom, $urandom});
  `define PD_CPU_CORRUPT_BLK(lhs, width) lhs = width'({$urandom, $urandom});
  `define PD_CPU_FORCE(lhs, width)   force lhs = off_rnd[width-1:0];
`endif

module tb_soc #(
  parameter ROM_INIT       = "build/fw/pm_test.hex",
  parameter COV_FILE       = "build/sim/coverage.txt",
  parameter int    EXT_WAKE_DELAY = 3000
);
  // ---------------- clocks / reset ----------------
  logic       clk_aon = 1'b0;
  // Separate scalar clocks (Verilator 5.020 misses edges when individual bits
  // of one vector are driven by different processes).
  logic       clk_op0 = 1'b0, clk_op1 = 1'b0, clk_op2 = 1'b0;
  wire  [2:0] clk_op  = {clk_op2, clk_op1, clk_op0};
  logic       por_n   = 1'b0;
  logic       uart_rx = 1'b1;
  logic       uart_tx;
  logic       ext_wake = 1'b0;
  logic [1:0] vsel;

  // Mutually asynchronous: AON 41 ns, OP0 47 ns, OP1 23 ns, OP2 11 ns.
  always #20.5 clk_aon   = ~clk_aon;
  always #23.5 clk_op0 = ~clk_op0;
  always #11.5 clk_op1 = ~clk_op1;
  initial begin
    #3.1;
    forever #5.5 clk_op2 = ~clk_op2;
  end

  soc_top #(
    .ROM_INIT (ROM_INIT)
  ) dut (
    .clk_aon_i (clk_aon), .clk_op_i (clk_op), .por_ni (por_n), .test_en_i (1'b0),
    .uart_rx_i (uart_rx), .uart_tx_o (uart_tx), .ext_wake_i (ext_wake), .vsel_o (vsel)
  );

  // ---------------- OFF-state corruption model ----------------
  logic [63:0] off_rnd;
  bit          break_iso;
  `include "pd_cpu_corrupt.svh"

  initial begin
    break_iso = $test$plusargs("break_iso");
    $display("[tb] corruption model: %0d state elements, %0d bits%s", PD_CPU_STATE_ELEMS,
             PD_CPU_STATE_BITS,
`ifdef CORRUPT_X
             " (X)"
`else
             " (random)"
`endif
             );
  end

  int n_corrupt;
  always @(negedge dut.pd_cpu_supply_on) if (por_n) begin
    off_rnd = {$urandom, $urandom};
    pd_cpu_corrupt_state();
    pd_cpu_force_outputs();
    n_corrupt++;
    if (break_iso) force dut.iso_en = 1'b0;
  end
  always @(posedge dut.pd_cpu_supply_on) if (por_n) begin
    pd_cpu_release_outputs();
    pd_cpu_corrupt_state();      // undefined power-up state until reset
    if (break_iso) release dut.iso_en;
  end

  // ---------------- reset, timeout, dump ----------------
  longint timeout_ns;
  initial begin
    if (!$value$plusargs("timeout=%d", timeout_ns)) timeout_ns = 64'd20_000_000;
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/sim/tb_soc.vcd");
      $dumpvars(0, tb_soc);
    end
    #200 por_n = 1'b1;
    #(timeout_ns);
    $display("[tb] FAIL: timeout after %0d ns", timeout_ns);
    finish_sim(1'b0);
  end

  // ---------------- UART monitor (8N1, DIV = 8 clk_aon cycles) ----------------
  localparam int UART_DIV = 8;
  string line = "";
  bit    seen_pass, seen_fail;

  initial begin : uart_mon
    logic [7:0] ch;
    forever begin
      @(negedge uart_tx);
      repeat (UART_DIV / 2) @(posedge clk_aon);
      for (int i = 0; i < 8; i++) begin
        repeat (UART_DIV) @(posedge clk_aon);
        ch[i] = uart_tx;
      end
      repeat (UART_DIV) @(posedge clk_aon);
      if (ch == 8'h0A) begin
        $display("[uart] %s", line);
        if (line == "PASS") seen_pass = 1'b1;
        if (line.len() >= 4 && line.substr(0, 3) == "FAIL") seen_fail = 1'b1;
        line = "";
        if (seen_pass || seen_fail) begin
          repeat (20) @(posedge clk_aon);
          finish_sim(seen_pass && !seen_fail);
        end
      end else if (ch != 8'h0D) begin
        line = {line, string'(ch)};
      end
    end
  end

  // ---------------- external wake pin stimulus ----------------
  localparam logic [4:0] ST_RUN = 5'd0, ST_IDLE = 5'd3, ST_OFF = 5'd10;
  wire [4:0] pmu_state = dut.u_aon.u_pmu.state_q;
  int off_cycles;
  always @(posedge clk_aon) begin
    off_cycles <= (pmu_state == ST_OFF) ? off_cycles + 1 : 0;
    if (off_cycles == EXT_WAKE_DELAY) begin
      ext_wake <= 1'b1;
      repeat (40) @(posedge clk_aon);
      ext_wake <= 1'b0;
    end
  end

  // ---------------- checkers ----------------
  int errors;
  bit checks_on;
  initial begin
    checks_on = 1'b0;
    wait (por_n);
    repeat (50) @(posedge clk_aon);
    checks_on = 1'b1;
  end

  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      if (errors <= 20) $display("[tb] ERROR @%0t: %s", $time, msg);
    end
  endtask

  // AON-side state and the isolated PD_CPU outputs must never be unknown.
  // (Written as "^(vec) !== 1'bx": Icarus' $isunknown misreports on
  // concatenations of hierarchical references.)
  always @(posedge clk_aon) if (checks_on) begin
    chk(((^({dut.u_aon.u_pmu.state_q, dut.iso_en, dut.pwr_sw_en, dut.cg_en,
                     dut.cpu_rst_req_n, dut.idle_req, dut.dvfs_sel, dut.vsel_o,
                     dut.u_aon.ram_ret})) !== 1'bx), "unknown PMU control");
    chk(((^({dut.a_awvalid, dut.a_wvalid, dut.a_arvalid, dut.a_bready, dut.a_rready,
                     dut.a_awready, dut.a_wready, dut.a_arready, dut.a_bvalid, dut.a_rvalid,
                     dut.bus_idle})) !== 1'bx), "unknown AON bus handshake");
    if (dut.a_awvalid) chk(((^(dut.a_awaddr)) !== 1'bx), "unknown AON awaddr");
    if (dut.a_wvalid)  chk(((^({dut.a_wdata, dut.a_wstrb})) !== 1'bx), "unknown AON wdata");
    if (dut.a_arvalid) chk(((^(dut.a_araddr)) !== 1'bx), "unknown AON araddr");
    chk(((^({dut.s_idle_ack, dut.s_core_sleep, dut.s_cache_clean})) !== 1'bx), "unknown core status");
    // isolation invariant
    if (!dut.pd_cpu_supply_on) chk(dut.iso_en === 1'b1, "PD_CPU supply off without isolation");
    // RAM periphery is off in retention: no access
    if (dut.u_aon.ram_ret) chk(dut.u_aon.u_ram.cs !== 1'b1, "RAM access during retention");
  end

  always @(posedge dut.clk_cpu) if (checks_on && dut.cpu_rst_n) begin
    chk(((^({dut.i_awvalid, dut.i_wvalid, dut.i_arvalid, dut.i_bready, dut.i_rready})) !== 1'bx),
        "unknown isolated PD_CPU handshake");
    if (dut.i_awvalid) chk(((^(dut.i_awaddr)) !== 1'bx), "unknown isolated awaddr");
    if (dut.i_wvalid)  chk(((^({dut.i_wdata, dut.i_wstrb})) !== 1'bx), "unknown isolated wdata");
    if (dut.i_arvalid) chk(((^(dut.i_araddr)) !== 1'bx), "unknown isolated araddr");
    chk(dut.i_trap !== 1'b1, "CPU trap");
  end

`ifdef SVA_ON
  a_iso_when_supply_off: assert property (@(posedge clk_aon) disable iff (!checks_on)
    !dut.pd_cpu_supply_on |-> dut.iso_en) else $error("PD_CPU off without isolation");
  a_rst_when_supply_off: assert property (@(posedge clk_aon) disable iff (!checks_on)
    !dut.pd_cpu_supply_on |-> !dut.cpu_rst_n) else $error("PD_CPU off without reset");
`endif

  // ---------------- power-state transition coverage ----------------
  // PMU FSM arcs (from -> to); must match rtl/aon/pmu.sv. Written with
  // functions/case (not array constants) so Icarus Verilog accepts it too.
  localparam int NARC = 24;
  function automatic logic [9:0] arc(input int a);
    case (a)
      0: arc = {5'd0, 5'd1};    1: arc = {5'd1, 5'd2};    2: arc = {5'd1, 5'd18};
      3: arc = {5'd2, 5'd3};    4: arc = {5'd2, 5'd7};    5: arc = {5'd3, 5'd4};
      6: arc = {5'd3, 5'd17};   7: arc = {5'd4, 5'd5};    8: arc = {5'd5, 5'd6};
      9: arc = {5'd6, 5'd3};   10: arc = {5'd7, 5'd8};   11: arc = {5'd7, 5'd17};
     12: arc = {5'd8, 5'd9};   13: arc = {5'd9, 5'd10};  14: arc = {5'd10, 5'd11};
     15: arc = {5'd10, 5'd12}; 16: arc = {5'd11, 5'd12}; 17: arc = {5'd12, 5'd13};
     18: arc = {5'd13, 5'd14}; 19: arc = {5'd14, 5'd15}; 20: arc = {5'd15, 5'd16};
     21: arc = {5'd16, 5'd17}; 22: arc = {5'd17, 5'd18}; 23: arc = {5'd18, 5'd0};
      default: arc = '1;
    endcase
  endfunction
  // Arcs that cannot be reached at SoC level with the PicoRV32 stand-in
  // (no D-cache: cache_clean is constant 1; the WFI-abort window depends on
  // clock phase). They are covered by the PMU unit test and by formal cover.
  function automatic bit arc_optional(input int a);
    return (a == 2) || (a == 11);
  endfunction
  function automatic string stn(input logic [4:0] st);
    case (st)
      0: stn = "RUN";          1: stn = "IDLE_REQ";     2: stn = "CLK_GATE";
      3: stn = "IDLE";         4: stn = "DVFS_VUP";     5: stn = "DVFS_SWITCH";
      6: stn = "DVFS_VDN";     7: stn = "BUS_DRAIN";    8: stn = "ISO_ON";
      9: stn = "PWR_OFF";     10: stn = "OFF";         11: stn = "RET_EXIT";
     12: stn = "PWR_ON";      13: stn = "RST_CLK_ON";  14: stn = "RST_CLK_OFF";
     15: stn = "RST_REL";     16: stn = "ISO_OFF";     17: stn = "CLK_UNGATE";
     18: stn = "WAKE_REL";
      default: stn = "?";
    endcase
  endfunction
  // Architectural power states: 0 RUN, 1 IDLE, 2 SLEEP, 3 DEEP_SLEEP
  function automatic string psn(input int p);
    case (p)
      0: psn = "RUN"; 1: psn = "IDLE"; 2: psn = "SLEEP"; default: psn = "DEEP_SLEEP";
    endcase
  endfunction

  int arc_hits [NARC];
  int illegal_arcs;
  int ps_hits [4][4];
  int ps_cur;
  int op_hits [3][3];
  logic [4:0] state_prev;
  logic [1:0] op_prev;
  logic [4:0] cov_s;
  logic [1:0] cov_op;
  int         cov_ps;
  bit         cov_found;

  always @(posedge clk_aon) if (por_n) begin
    cov_s  = pmu_state;
    cov_op = dut.u_aon.u_pmu.cur_op_q;
    cov_ps = -1;
    if (checks_on && cov_s != state_prev) begin
      cov_found = 1'b0;
      for (int a = 0; a < NARC; a++)
        if (arc(a) == {state_prev, cov_s}) begin arc_hits[a]++; cov_found = 1'b1; end
      if (!cov_found) begin
        illegal_arcs++;
        $display("[tb] ERROR: illegal PMU transition %0d -> %0d", state_prev, cov_s);
      end
    end
    if (cov_s == ST_RUN)  cov_ps = 0;
    if (cov_s == ST_IDLE) cov_ps = 1;
    if (cov_s == ST_OFF)  cov_ps = dut.u_aon.ram_ret ? 3 : 2;
    if (cov_ps >= 0 && cov_ps != ps_cur) begin
      ps_hits[ps_cur][cov_ps]++;
      ps_cur = cov_ps;
    end
    if (checks_on && cov_op != op_prev) op_hits[op_prev][cov_op]++;
    state_prev <= cov_s;
    op_prev    <= cov_op;
  end

  initial begin
    state_prev = 5'd0;
    op_prev    = 2'd2;
    ps_cur     = 0;
  end

  function automatic int coverage_report(input int fd);
    int missing = 0, hit = 0;
    $fdisplay(fd, "== PMU FSM transition coverage ==");
    for (int a = 0; a < NARC; a++) begin
      $fdisplay(fd, "  %-12s -> %-12s %6d %s", stn(arc(a) >> 5), stn(arc(a) & 10'h1F), arc_hits[a],
                arc_hits[a] > 0 ? "" : (arc_optional(a) ? "(not reachable at SoC level)" : "MISSING"));
      if (arc_hits[a] > 0) hit++;
      else if (!arc_optional(a)) missing++;
    end
    $fdisplay(fd, "  arcs hit: %0d/%0d, illegal transitions: %0d", hit, NARC, illegal_arcs);
    $fdisplay(fd, "== Architectural power-state transitions ==");
    for (int f = 0; f < 4; f++)
      for (int t = 0; t < 4; t++)
        if ((f == 0) != (t == 0)) begin
          $fdisplay(fd, "  %-10s -> %-10s %6d %s", psn(f), psn(t), ps_hits[f][t],
                    ps_hits[f][t] > 0 ? "" : "MISSING");
          if (ps_hits[f][t] == 0) missing++;
        end
    $fdisplay(fd, "== DVFS operating-point transitions ==");
    for (int f = 0; f < 3; f++)
      for (int t = 0; t < 3; t++)
        if (f != t) begin
          $fdisplay(fd, "  OP%0d -> OP%0d %6d %s", f, t, op_hits[f][t], op_hits[f][t] > 0 ? "" : "MISSING");
          if (op_hits[f][t] == 0) missing++;
        end
    $fdisplay(fd, "  PD_CPU corruption events: %0d", n_corrupt);
    return missing;
  endfunction

`ifdef TB_DEBUG_INC
  `include `TB_DEBUG_INC
`endif

  task automatic finish_sim(input bit fw_pass);
    int fd, missing;
    missing = coverage_report(32'h8000_0001);  // stdout
    fd = $fopen(COV_FILE, "w");
    if (fd != 0) begin
      void'(coverage_report(fd));
      $fclose(fd);
    end
    if (fw_pass && errors == 0 && missing == 0 && illegal_arcs == 0) begin
      $display("[tb] TEST PASSED");
    end else begin
      $display("[tb] TEST FAILED (firmware=%s, checker errors=%0d, coverage holes=%0d, illegal arcs=%0d)",
               fw_pass ? "pass" : "fail", errors, missing, illegal_arcs);
      $fatal(1, "tb_soc failed");
    end
    $finish;
  endtask
endmodule
