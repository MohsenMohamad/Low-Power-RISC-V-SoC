// -----------------------------------------------------------------------------
// tb_soc - SoC-level testbench (Verilator and Icarus Verilog)
//
// * Runs firmware on the integrated SoC (in-house RV32IM core with I-/D-cache
//   in PD_CPU): the boot ROM image (+rom=<hex>, default build/fw/lpsoc/rom.hex)
//   and, acting as the host (doc/BOOT_ABI.md), an application image preloaded
//   into RAM (+ram=<hex>) and a boot argument in the host mailbox
//   (+bootarg=<hex>). Test completion: the firmware prints a line "PASS" or
//   "FAIL ..." on the UART.
// * UART console: every received line is shown as "[uart] ..."; +uart_log=<f>
//   records the raw TX byte stream; +uart_in=<f> feeds the RX line, one line
//   each time the firmware prints the prompt "mon> " (the line after a
//   "zzz> " prompt is held back +wake_delay=<n> clk_aon cycles, default 60000,
//   so the firmware is asleep before the byte that wakes it arrives).
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
//   transitions and DVFS operating-point transitions, written as "COV" lines to
//   +cov=<file> (default build/sim/coverage.txt). Coverage goals and waivers
//   are checked by scripts/check_soc_cov.py, not here.
// * A requested power-down that the PMU refused (dirty D-cache) or that was
//   aborted before the clock gate is reported as ABORTED; it is never counted
//   as a completed transition, as coverage, or in the latency statistics.
// Plusargs: +rom=<hex> +ram=<hex> +bootarg=<hex> +cov=<file> +vcd +timeout=<ns>
//           +uart_in=<file> +uart_log=<file> +wake_delay=<n>
//           +break_iso (negative test: defeat isolation)
//           +neg_short_rst (negative test: too short PD_CPU reset pulse)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`define PD_CPU_PATH tb_soc.dut.u_pd_cpu
// Corruption values are cast to the target's own type (enum-typed state).
// Icarus (CORRUPT_X) simulates the sv2v-converted RTL, which has no enums.
`ifdef CORRUPT_X
  `define PD_CPU_CORRUPT(lhs, width) lhs <= 'x;
  `define PD_CPU_CORRUPT_BLK(lhs, width) lhs = 'x;
  `define PD_CPU_FORCE(lhs, width)   force lhs = 'x;
`else
  `define PD_CPU_CORRUPT(lhs, width) lhs <= type(lhs)'(width'({$urandom, $urandom, $urandom, $urandom}));
  `define PD_CPU_CORRUPT_BLK(lhs, width) lhs = type(lhs)'(width'({$urandom, $urandom, $urandom, $urandom}));
  `define PD_CPU_FORCE(lhs, width)   force lhs = off_rnd[width-1:0];
`endif

module tb_soc #(
  parameter ROM_INIT       = "",                   // ROM image is loaded from +rom=<hex>
  parameter int    EXT_WAKE_DELAY = 3000
);
  string COV_FILE;
  initial if (!$value$plusargs("cov=%s", COV_FILE)) COV_FILE = "build/sim/coverage.txt";
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

  // ---------------- boot ROM image ----------------
  initial begin
    string rom;
    if (!$value$plusargs("rom=%s", rom)) rom = "build/fw/lpsoc/rom.hex";
    #1;  // after the ROM model's own initialisation
    for (int i = 0; i < 4096; i++) dut.u_aon.u_rom.g_rom.u_rom.mem[i] = 32'h0000_0013;
    $readmemh(rom, dut.u_aon.u_rom.g_rom.u_rom.mem);
    if (dut.u_aon.u_rom.g_rom.u_rom.mem[0] === 32'h0000_0013 || $isunknown(dut.u_aon.u_rom.g_rom.u_rom.mem[0]))
      $fatal(1, "[tb] ROM image %s not loaded", rom);
    $display("[tb] ROM image: %s", rom);
  end

  // ---------------- main RAM power-up content ----------------
  // An SRAM powers up with arbitrary but defined bits. The 4-state X check
  // below must flag only X injected by the PD_CPU corruption model, not X from
  // never-written RAM words that the write-back D-cache refills and writes
  // back as part of a full line. Random words, seeded (+ram_seed).
  initial begin
    int unsigned rs;
    if (!$value$plusargs("ram_seed=%d", rs)) rs = 1;
    void'($urandom(rs));
    #1;
    for (int i = 0; i < 32768; i++) dut.u_aon.u_ram.g_ram.u_ram.mem[i] = $urandom;
  end

  // ---------------- host: application image and boot argument ----------------
  // (doc/BOOT_ABI.md: image at RAM+0x1000, host mailbox at RAM+0x100)
  initial begin
    string ram;
    logic [31:0] barg;
    #2;  // after the power-up content above
    if ($value$plusargs("ram=%s", ram)) begin
      $readmemh(ram, dut.u_aon.u_ram.g_ram.u_ram.mem);
      if (dut.u_aon.u_ram.g_ram.u_ram.mem[32'h1000 / 4] !== 32'h5041_504C)
        $fatal(1, "[tb] RAM image %s not loaded (no image header at RAM+0x1000)", ram);
      $display("[tb] RAM image: %s", ram);
    end
    if ($value$plusargs("bootarg=%h", barg)) begin
      dut.u_aon.u_ram.g_ram.u_ram.mem[32'h100 / 4] = 32'h4841_5247;   // "HARG"
      dut.u_aon.u_ram.g_ram.u_ram.mem[32'h104 / 4] = barg;
      $display("[tb] boot argument 0x%08h", barg);
    end
  end

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
    if (!$value$plusargs("timeout=%d", timeout_ns)) timeout_ns = 64'd60_000_000;
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

  int    uart_log_fd;
  int    uart_frame_errs;
  string tx_tail = "";
  bit    prompt_seen;      // the firmware waits for the next input line
  int    rx_hold;          // clk_aon cycles before the next line may start
  int    wake_delay;
  initial begin
    string f;
    if ($value$plusargs("uart_log=%s", f)) uart_log_fd = $fopen(f, "w");
    if (!$value$plusargs("wake_delay=%d", wake_delay)) wake_delay = 60000;
  end

  function automatic bit ends_with(string str, string suffix);
    if (str.len() < suffix.len()) return 1'b0;
    return str.substr(str.len() - suffix.len(), str.len() - 1) == suffix;
  endfunction

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
      if (uart_tx !== 1'b1) begin
        uart_frame_errs++;
        $display("[tb] ERROR: UART framing error (stop bit)");
      end
      if (uart_log_fd != 0) $fwrite(uart_log_fd, "%c", ch);
      tx_tail = {tx_tail, string'(ch)};
      if (tx_tail.len() > 16) tx_tail = tx_tail.substr(tx_tail.len() - 16, tx_tail.len() - 1);
      if (ends_with(tx_tail, "mon> ")) prompt_seen = 1'b1;
      if (ends_with(tx_tail, "zzz> ")) begin prompt_seen = 1'b1; rx_hold = wake_delay; end
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

  // ---------------- UART RX driver (+uart_in) ----------------
  // One input line per prompt: the line starts once the firmware printed its
  // prompt; bytes of a line follow each other with a 4-bit-time gap.
  byte unsigned rx_buf[$];
  initial begin
    string f;
    int fd, c;
    if ($value$plusargs("uart_in=%s", f)) begin
      fd = $fopen(f, "rb");
      if (fd == 0) $fatal(1, "[tb] cannot open %s", f);
      c = $fgetc(fd);
      while (c != -1) begin       // (no assignment in the condition: Icarus)
        rx_buf.push_back(c[7:0]);
        c = $fgetc(fd);
      end
      $fclose(fd);
    end
  end
  always @(posedge clk_aon) if (rx_hold > 0) rx_hold <= rx_hold - 1;
  initial begin : uart_drv
    byte unsigned b;
    wait (por_n);
    forever begin
      @(posedge clk_aon);
      if (rx_buf.size() != 0 && prompt_seen && rx_hold == 0) begin
        do begin
          b = rx_buf.pop_front();
          uart_rx = 1'b0;                                   // start bit
          repeat (UART_DIV) @(posedge clk_aon);
          for (int i = 0; i < 8; i++) begin
            uart_rx = b[i];
            repeat (UART_DIV) @(posedge clk_aon);
          end
          uart_rx = 1'b1;                                   // stop bit + gap
          repeat (5 * UART_DIV) @(posedge clk_aon);
        end while (b != 8'h0A && rx_buf.size() != 0);
        prompt_seen = 1'b0;     // a prompt printed while the line was sent is not a new request
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
  end

  // Interface requirement of the mtime crossing (rtl/common/cdc_snapshot_src.sv,
  // proven in formal/cdc_snapshot.sby under it): a PD_CPU reset lasts at least
  // 6 clk_aon edges.
  int rst_aon_edges;
  // Negative test of this check (+neg_short_rst): a 2-cycle PD_CPU reset pulse.
  initial if ($test$plusargs("neg_short_rst")) begin
    wait (checks_on);
    repeat (2000) @(posedge clk_aon);
    force dut.cpu_rst_n = 1'b0;
    repeat (2) @(posedge clk_aon);
    release dut.cpu_rst_n;
  end
  always @(posedge clk_aon) begin
    if (!dut.cpu_rst_n) rst_aon_edges <= rst_aon_edges + 1;
    else begin
      if (checks_on && rst_aon_edges != 0 && rst_aon_edges < 6)
        chk(1'b0, $sformatf("PD_CPU reset lasted only %0d clk_aon edges (< 6)", rst_aon_edges));
      rst_aon_edges <= 0;
    end
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
  // Arcs 0..23: power management; 24..29: watchdog reset (reported as the
  // separate group "wdt_arc", doc/SOC_REGMAP.md "Watchdog reset").
  localparam int NARC = 30;
  localparam int NARC_PM = 24;
  function automatic logic [9:0] arc(input int a);
    case (a)
      0: arc = {5'd0, 5'd1};    1: arc = {5'd1, 5'd2};    2: arc = {5'd1, 5'd18};
      3: arc = {5'd2, 5'd3};    4: arc = {5'd2, 5'd7};    5: arc = {5'd3, 5'd4};
      6: arc = {5'd3, 5'd17};   7: arc = {5'd4, 5'd5};    8: arc = {5'd5, 5'd6};
      9: arc = {5'd6, 5'd3};   10: arc = {5'd7, 5'd8};   11: arc = {5'd7, 5'd3};
     12: arc = {5'd8, 5'd9};   13: arc = {5'd9, 5'd10};  14: arc = {5'd10, 5'd11};
     15: arc = {5'd10, 5'd12}; 16: arc = {5'd11, 5'd12}; 17: arc = {5'd12, 5'd13};
     18: arc = {5'd13, 5'd14}; 19: arc = {5'd14, 5'd15}; 20: arc = {5'd15, 5'd16};
     21: arc = {5'd16, 5'd17}; 22: arc = {5'd17, 5'd18}; 23: arc = {5'd18, 5'd0};
     24: arc = {5'd0, 5'd19};  25: arc = {5'd19, 5'd20}; 26: arc = {5'd20, 5'd8};
     27: arc = {5'd20, 5'd17}; 28: arc = {5'd3, 5'd8};   29: arc = {5'd8, 5'd12};
      default: arc = '1;
    endcase
  endfunction
  function automatic string stn(input logic [4:0] st);
    case (st)
      0: stn = "RUN";          1: stn = "IDLE_REQ";     2: stn = "CLK_GATE";
      3: stn = "IDLE";         4: stn = "DVFS_VUP";     5: stn = "DVFS_SWITCH";
      6: stn = "DVFS_VDN";     7: stn = "BUS_DRAIN";    8: stn = "ISO_ON";
      9: stn = "PWR_OFF";     10: stn = "OFF";         11: stn = "RET_EXIT";
     12: stn = "PWR_ON";      13: stn = "RST_CLK_ON";  14: stn = "RST_CLK_OFF";
     15: stn = "RST_REL";     16: stn = "ISO_OFF";     17: stn = "CLK_UNGATE";
     18: stn = "WAKE_REL";    19: stn = "WDT_GATE";    20: stn = "WDT_CHECK";
      default: stn = "?";
    endcase
  endfunction
  // Architectural power states: 0 RUN, 1 IDLE, 2 SLEEP, 3 DEEP_SLEEP
  function automatic string psn(input int p);
    case (p)
      0: psn = "RUN"; 1: psn = "IDLE"; 2: psn = "SLEEP"; default: psn = "DEEP_SLEEP";
    endcase
  endfunction

  // ---------------- power-state latency measurement ----------------
  // Entry: WFI retired in the core (wfi_sleep_q rises, PD_CPU clock) -> PMU reaches
  //        IDLE (clock gated) / OFF (switch off, isolated, reset).
  // Wake:  wake event seen by the PMU in IDLE/OFF -> PMU back in RUN.
  // Index: 0 IDLE, 1 SLEEP, 2 DEEP_SLEEP
  realtime t_wfi, t_wake;
  realtime lat_ent_min [3], lat_ent_max [3], lat_ent_sum [3];
  realtime lat_wak_min [3], lat_wak_max [3], lat_wak_sum [3];
  int      lat_ent_n [3], lat_wak_n [3];
  int      lp_kind;
  always @(posedge dut.u_pd_cpu.u_cpu.u_core.wfi_sleep_q)
    if (dut.pd_cpu_supply_on && dut.cpu_rst_n) t_wfi = $realtime;  // ignore corruption events

  task automatic lat_add(input bit wake, input int k, input realtime d);
    if (!wake) begin
      if (lat_ent_n[k] == 0 || d < lat_ent_min[k]) lat_ent_min[k] = d;
      if (lat_ent_n[k] == 0 || d > lat_ent_max[k]) lat_ent_max[k] = d;
      lat_ent_sum[k] += d; lat_ent_n[k]++;
    end else begin
      if (lat_wak_n[k] == 0 || d < lat_wak_min[k]) lat_wak_min[k] = d;
      if (lat_wak_n[k] == 0 || d > lat_wak_max[k]) lat_wak_max[k] = d;
      lat_wak_sum[k] += d; lat_wak_n[k]++;
    end
  endtask

  always @(posedge clk_aon) if (checks_on) begin
    // entries (only the first IDLE entry of an episode, not the return from DVFS
    // and not a refused power-down)
    if (dut.u_aon.u_pmu.state_q == 5'd2 && dut.u_aon.u_pmu.state_d == 5'd3) begin
      lat_add(1'b0, 0, $realtime - t_wfi); lp_kind = 0;
    end
    if (dut.u_aon.u_pmu.state_q == 5'd9 && dut.u_aon.u_pmu.state_d == 5'd10) begin
      lp_kind = (dut.u_aon.u_pmu.mode_lat_q == 2'd2) ? 2 : 1;
      lat_add(1'b0, lp_kind, $realtime - t_wfi);
    end
    // wake event accepted
    if (((dut.u_aon.u_pmu.state_q == 5'd3 && dut.u_aon.u_pmu.state_d == 5'd17) ||
         (dut.u_aon.u_pmu.state_q == 5'd10 && dut.u_aon.u_pmu.state_d != 5'd10)) && !ep_aborted &&
        !dut.u_aon.u_pmu.wdt_pend_q)
      t_wake = $realtime;   // (a watchdog reset is not a wake: no latency sample)
    if (dut.u_aon.u_pmu.state_q == 5'd18 && dut.u_aon.u_pmu.state_d == 5'd0 && t_wake > 0) begin
      lat_add(1'b1, lp_kind, $realtime - t_wake);
      t_wake = 0;
    end
  end

  function automatic void latency_report(input int fd);
    $fdisplay(fd, "== Power-state latency (ns): clk_aon 41 ns, clk_cpu OP0/1/2 47/23/11 ns ==");
    for (int k = 0; k < 3; k++) begin
      if (lat_ent_n[k] > 0)
        $fdisplay(fd, "  %-10s entry  (WFI retired -> %s)  n=%0d min=%0.0f max=%0.0f avg=%0.0f",
                  psn(k + 1), k == 0 ? "clock gated" : "power off  ", lat_ent_n[k],
                  lat_ent_min[k], lat_ent_max[k], lat_ent_sum[k] / lat_ent_n[k]);
      if (lat_wak_n[k] > 0)
        $fdisplay(fd, "  %-10s wake   (wake event -> PMU RUN)       n=%0d min=%0.0f max=%0.0f avg=%0.0f",
                  psn(k + 1), lat_wak_n[k], lat_wak_min[k], lat_wak_max[k], lat_wak_sum[k] / lat_wak_n[k]);
    end
  endfunction

  int arc_hits [NARC];
  int illegal_arcs;
  bit ep_aborted;          // current low-power episode was refused / aborted
  bit ep_wdt;              // current episode ended in a watchdog reset (not a wake)
  int wdt_resets;          // completed watchdog reset sequences
  int aborted [4];         // by requested architectural state (1 IDLE, 2 SLEEP, 3 DEEP_SLEEP)
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
    // Aborted / refused low-power entries (doc/SPEC.md verification rules):
    //   IDLE_REQ -> WAKE_REL : the core left WFI before acknowledging
    //   BUS_DRAIN -> IDLE    : power-down refused (dirty D-cache / no idle_ack)
    if (checks_on && cov_s != state_prev &&
        ((state_prev == 5'd1 && cov_s == 5'd18) || (state_prev == 5'd7 && cov_s == ST_IDLE))) begin
      int req;
      req = (dut.u_aon.u_pmu.mode_lat_q == 2'd0) ? 1 : (dut.u_aon.u_pmu.mode_lat_q == 2'd2) ? 3 : 2;
      aborted[req]++;
      ep_aborted = 1'b1;
      if (state_prev == 5'd1)
        $display("[tb] ABORTED transition RUN -> %s (core left WFI before idle_ack) @%0t", psn(req), $time);
      else
        $display("[tb] ABORTED transition RUN -> %s (power-down refused by PMU) @%0t", psn(req), $time);
    end
    // Watchdog reset (doc/SOC_REGMAP.md): the return to RUN is a reset, not a
    // completed power-state transition.
    if (cov_s == 5'd19 || dut.u_aon.u_pmu.wdt_seq_q) ep_wdt = 1'b1;
    if (checks_on && cov_s != state_prev && state_prev == 5'd15 && dut.u_aon.u_pmu.wdt_seq_q) begin
      wdt_resets++;
      $display("[tb] watchdog reset of PD_CPU @%0t", $time);
    end
    if (cov_s == ST_RUN) begin
      cov_ps = 0;
    end
    if (cov_s == ST_IDLE && !ep_aborted) cov_ps = 1;
    if (cov_s == ST_OFF)  cov_ps = dut.u_aon.ram_ret ? 3 : 2;
    if (cov_ps >= 0 && cov_ps != ps_cur) begin
      // the return to RUN after an aborted episode is not a completed transition
      if (!((ep_aborted || ep_wdt) && cov_ps == 0)) ps_hits[ps_cur][cov_ps]++;
      ps_cur = cov_ps;
    end
    if (cov_s == ST_RUN) begin ep_aborted = 1'b0; ep_wdt = 1'b0; t_wake = 0; end
    if (checks_on && cov_op != op_prev) op_hits[op_prev][cov_op]++;
    state_prev <= cov_s;
    op_prev    <= cov_op;
  end

  initial begin
    state_prev = 5'd0;
    op_prev    = 2'd2;
    ps_cur     = 0;
  end

  // One "COV <group> <bin> <count>" line per coverage bin (machine readable;
  // goals and waivers are applied by scripts/check_soc_cov.py).
  function automatic void coverage_report(input int fd);
    int hit = 0;
    $fdisplay(fd, "== PMU FSM transition coverage ==");
    for (int a = 0; a < NARC; a++) begin
      if (a < NARC_PM)
        $fdisplay(fd, "COV arc %s->%s %0d", stn(arc(a) >> 5), stn(arc(a) & 10'h1F), arc_hits[a]);
      else
        $fdisplay(fd, "COV wdt_arc %s->%s %0d", stn(arc(a) >> 5), stn(arc(a) & 10'h1F), arc_hits[a]);
      if (arc_hits[a] > 0 && a < NARC_PM) hit++;
    end
    $fdisplay(fd, "  arcs hit: %0d/%0d, illegal transitions: %0d", hit, NARC_PM, illegal_arcs);
    $fdisplay(fd, "COV illegal transitions %0d", illegal_arcs);
    $fdisplay(fd, "COV wdt resets %0d", wdt_resets);
    $fdisplay(fd, "== Architectural power-state transitions (completed only) ==");
    for (int f = 0; f < 4; f++)
      for (int t = 0; t < 4; t++)
        if ((f == 0) != (t == 0))
          $fdisplay(fd, "COV pstate %s->%s %0d", psn(f), psn(t), ps_hits[f][t]);
    $fdisplay(fd, "== Aborted / refused transitions (never counted as coverage) ==");
    for (int r = 1; r < 4; r++)
      $fdisplay(fd, "COV aborted RUN->%s %0d", psn(r), aborted[r]);
    $fdisplay(fd, "== DVFS operating-point transitions ==");
    for (int f = 0; f < 3; f++)
      for (int t = 0; t < 3; t++)
        if (f != t) $fdisplay(fd, "COV dvfs OP%0d->OP%0d %0d", f, t, op_hits[f][t]);
    $fdisplay(fd, "COV corrupt events %0d", n_corrupt);
    latency_report(fd);
  endfunction

`ifdef TB_DEBUG_INC
  `include `TB_DEBUG_INC
`endif

  task automatic finish_sim(input bit fw_pass);
    int fd;
    coverage_report(32'h8000_0001);  // stdout
    fd = $fopen(COV_FILE, "w");
    if (fd != 0) begin
      coverage_report(fd);
      $fclose(fd);
    end else begin
      errors++;
      $display("[tb] ERROR: cannot write coverage file %s", COV_FILE);
    end
    if (uart_log_fd != 0) $fclose(uart_log_fd);
    errors += uart_frame_errs;
    if (fw_pass && errors == 0 && illegal_arcs == 0) begin
      $display("[tb] TEST PASSED");
    end else begin
      $display("[tb] TEST FAILED (firmware=%s, checker errors=%0d, illegal arcs=%0d)",
               fw_pass ? "pass" : "fail", errors, illegal_arcs);
      $fatal(1, "tb_soc failed");
    end
    $finish;
  endtask
endmodule
