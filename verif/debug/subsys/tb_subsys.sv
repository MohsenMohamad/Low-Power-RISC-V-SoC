// Testbench for dbg_subsys (AXI4-Lite demux + block wiring).
//
// Tests (+TEST=<name>):
//   subsys_smoke      IDs and scratch registers of all four blocks through the
//                     wrapper, unmapped offsets -> SLVERR, random AXI traffic to
//                     random blocks under protocol SVA
//   subsys_wdt_chain  hang scenario: trace capturing, watchdog bites ->
//                     error log records WDT_BITE (handshake) -> freeze_o
//                     freezes the trace buffer and the event counters -> PD_CPU
//                     reset request pulse -> WDT_RST sticky; everything
//                     readable afterwards with PD_CPU off
`timescale 1ns/1ps
module tb_subsys;
  import dbg_pkg::*;
  import dbg_tb_pkg::*;

  logic clk_aon = 1'b0, clk_cpu_free = 1'b0, rst_n = 1'b0;
  logic cpu_clk_en = 1'b1, cpu_clk_en_l, clk_cpu;
  clk_cfg ccfg;
  int unsigned seed = 1;
  string test = "subsys_smoke";
  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("TEST=%s", test));
    ccfg = new();
    if (ccfg.randomize() == 0) $fatal(1, "clk_cfg randomize failed");
    $display("tb_subsys: test=%s seed=%0d", test, seed);
    fork
      forever #(ccfg.aon_half_ps * 1ps) clk_aon = ~clk_aon;
      begin #(ccfg.cpu_phase_ps * 1ps); forever #(ccfg.cpu_half_ps * 1ps) clk_cpu_free = ~clk_cpu_free; end
    join_none
  end
  always_latch if (!clk_cpu_free) cpu_clk_en_l = cpu_clk_en;
  assign clk_cpu = clk_cpu_free & cpu_clk_en_l;

  dbg_axil_if axi (.clk(clk_aon), .rst_n(rst_n));
  logic        ret_valid = 0, trap_valid = 0;
  logic [31:0] ret_pc = 0, ret_insn = 0;
  logic [4:0]  ev = '0;
  logic [1:0]  pwr_state = PS_RUN;
  logic        rst_req, wdt_irq, err_irq;

  dbg_subsys #(.TRACE_DEPTH(16)) dut (
    .clk_aon_i(clk_aon), .rst_aon_ni(rst_n), .clk_cpu_i(clk_cpu),
    .s_axil_awaddr(axi.awaddr), .s_axil_awprot(axi.awprot), .s_axil_awvalid(axi.awvalid),
    .s_axil_awready(axi.awready), .s_axil_wdata(axi.wdata), .s_axil_wstrb(axi.wstrb),
    .s_axil_wvalid(axi.wvalid), .s_axil_wready(axi.wready), .s_axil_bresp(axi.bresp),
    .s_axil_bvalid(axi.bvalid), .s_axil_bready(axi.bready), .s_axil_araddr(axi.araddr),
    .s_axil_arprot(axi.arprot), .s_axil_arvalid(axi.arvalid), .s_axil_arready(axi.arready),
    .s_axil_rdata(axi.rdata), .s_axil_rresp(axi.rresp), .s_axil_rvalid(axi.rvalid),
    .s_axil_rready(axi.rready),
    .ret_valid_i(ret_valid), .ret_pc_i(ret_pc), .ret_insn_i(ret_insn),
    .trap_valid_i(trap_valid), .trap_cause_i(32'd0), .trap_pc_i(32'd0), .trap_tval_i(32'd0),
    .ic_hit_i(ev[0]), .ic_miss_i(ev[1]), .dc_hit_i(ev[2]), .dc_miss_i(ev[3]), .stall_i(ev[4]),
    .pwr_state_i(pwr_state), .dvfs_op_i(2'd0), .pmu_evt_valid_i(1'b0), .pmu_evt_from_i(2'd0),
    .pmu_evt_to_i(2'd0), .pmu_evt_result_i(2'd0),
    .cpu_rst_req_o(rst_req), .wdt_irq_o(wdt_irq), .err_irq_o(err_irq));

  // The wrapper is one-cycle too (write needs AW and W together).
  dbg_axil_sva #(.AW(14), .ONE_CYCLE(1'b0)) u_axi_sva (
    .clk(clk_aon), .rst_n(rst_n),
    .awaddr(axi.awaddr), .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wvalid(axi.wvalid), .wready(axi.wready),
    .bresp(axi.bresp), .bvalid(axi.bvalid), .bready(axi.bready),
    .araddr(axi.araddr), .arvalid(axi.arvalid), .arready(axi.arready),
    .rdata(axi.rdata), .rresp(axi.rresp), .rvalid(axi.rvalid), .rready(axi.rready));

  localparam logic [13:0] TRC = 14'h0000, EVC = 14'h1000, ERR = 14'h2000, WDT = 14'h3000;

  axil_master bfm;

  task automatic aon_wait(int unsigned n); repeat (n) @(posedge clk_aon); endtask

  class rand_access;
    rand bit [1:0]  blk;
    rand bit [11:0] off;
    rand bit        is_wr;
    rand bit [31:0] data;
    constraint c_off { off[1:0] == 0; off dist {[0:12'h05C] := 8, [12'h800:12'h8FC] := 2, [12'h060:12'h7FC] := 1}; }
    // never write the watchdog CTRL/KICK or trace/evcnt CTRL at random
    constraint c_safe { is_wr -> !((blk == 3 && off inside {12'h004, 12'h014}) || (blk inside {0, 1} && off == 12'h004)); }
  endclass

  task automatic test_smoke();
    logic [31:0] v;
    logic [1:0]  r;
    rand_access  ra = new();
    bfm.rd(TRC, v); check_eq(v, 32'hDB60_0101, "trace ID");
    bfm.rd(EVC, v); check_eq(v, 32'hDB60_0201, "evcnt ID");
    bfm.rd(ERR, v); check_eq(v, 32'hDB60_0301, "errlog ID");
    bfm.rd(WDT, v); check_eq(v, 32'hDB60_0401, "wdt ID");
    bfm.wr(TRC + 14'h010, 32'h1234_5678); bfm.rd(TRC + 14'h010, v); check_eq(v, 32'h1234_5678, "trace START_PC");
    bfm.wr(ERR + 14'h00C, 32'h3F);         bfm.rd(ERR + 14'h00C, v); check_eq(v, 32'h3F, "errlog IRQ_EN");
    bfm.wr(WDT + 14'h008, 32'hCAFE);       bfm.rd(WDT + 14'h008, v); check_eq(v, 32'hCAFE, "wdt LOAD");
    bfm.read(EVC + 14'h400, v, r);  check(r == 2'b10, "unmapped read -> SLVERR");
    bfm.write(WDT + 14'h010, 1, r); check(r == 2'b10, "read-only write -> SLVERR");
    bfm.write(ERR + 14'h004, 0, r, 4'h3); check(r == 2'b10, "partial strobe -> SLVERR");
    repeat (300) begin
      if (ra.randomize() == 0) $fatal(1, "rand_access randomize failed");
      if (ra.is_wr) bfm.write({ra.blk, ra.off}, ra.data, r);
      else          bfm.read({ra.blk, ra.off}, v, r);
    end
    check(bfm.n_rd + bfm.n_wr > 300, "random traffic completed");
  endtask

  task automatic test_wdt_chain();
    logic [31:0] v, tot0, tot1, ic0, ic1;
    int unsigned rst_cycles = 0;
    // trace: capture everything, freeze on error; counters freeze on error
    bfm.wr(TRC + 14'h004, 32'h0000_0043);        // EN, CLEAR, FRZ_ERR (bit 6)
    bfm.wr(EVC + 14'h004, 32'h0000_0006);        // CLEAR, FRZ_ERR
    bfm.wr(WDT + 14'h008, 32'd200);
    bfm.wr(WDT + 14'h004, 32'h0000_0005);        // EN, RST_EN
    // the CPU "hangs" in a loop: retires keep coming but nobody kicks
    fork
      begin
        int unsigned k = 0;
        while (!rst_req) begin
          @(negedge clk_cpu);
          ret_valid = 1; ret_pc = 32'h100 + 32'(k % 4) * 4; ret_insn = 32'h0000_006F; ev = 5'b00101;
          k++;
        end
        @(negedge clk_cpu); ret_valid = 0; ev = '0;
      end
      begin
        while (!rst_req) @(posedge clk_aon);
        while (rst_req) begin rst_cycles++; @(posedge clk_aon); end
      end
    join
    check(rst_cycles == 16, $sformatf("reset request pulse is 16 cycles (got %0d)", rst_cycles));
    // PD_CPU is now reset / off: gate its clock
    @(negedge clk_cpu_free); cpu_clk_en = 0;
    @(negedge clk_aon) pwr_state = PS_SLEEP;
    aon_wait(20);
    bfm.rd(ERR + 14'h004, v);
    check(v[3] && v[4], $sformatf("errlog STATUS has WDT_BITE and WDT_RST (0x%02x)", v));
    bfm.rd(ERR + 14'h050, v); check_eq(v, 1, "errlog WDT_CNT");
    bfm.rd(ERR + 14'h058, v); check_eq(v, PS_RUN, "errlog WDT_PSTATE (hung while running)");
    bfm.rd(WDT + 14'h01C, v); check_eq(v, 1, "wdt RST_CNT");
    bfm.rd(TRC + 14'h008, v); check(v[1], "trace frozen by the error log");
    bfm.rd(TRC + 14'h028, tot0);
    bfm.rd(TRC + 14'h020, v);   check_eq(v, 16, "trace full (wrapped)");
    bfm.rd(TRC + 14'h800 + 14'(16 * ((tot0 - 1) % 16)), v);
    check(v inside {32'h100, 32'h104, 32'h108, 32'h10C}, "last traced PC is in the hang loop");
    bfm.rd(EVC + 14'h008, v);   check(v[0], "event counters frozen by the error log");
    bfm.rd(EVC + 14'h010, ic0);
    check(ic0 > 0, "I$ hits counted before the hang was detected");
    // wake PD_CPU: still frozen, no new entries even with activity
    @(negedge clk_aon) pwr_state = PS_RUN;
    @(negedge clk_cpu_free); cpu_clk_en = 1;
    repeat (30) begin
      @(negedge clk_cpu); ret_valid = 1; ev = 5'b00001;
    end
    @(negedge clk_cpu); ret_valid = 0; ev = '0;
    aon_wait(10);
    bfm.rd(TRC + 14'h028, tot1); check_eq(tot1, tot0, "frozen trace takes no new entries");
    bfm.rd(EVC + 14'h010, ic1);  check_eq(ic1, ic0, "frozen counters hold");
    // firmware clears the error and the trace: capture resumes
    bfm.wr(ERR + 14'h004, 32'h3F);
    bfm.wr(TRC + 14'h004, 32'h0000_0043);
    aon_wait(10);
    repeat (5) begin @(negedge clk_cpu); ret_valid = 1; end
    @(negedge clk_cpu); ret_valid = 0;
    aon_wait(12);
    bfm.rd(TRC + 14'h028, v); check_eq(v, 5, "trace captures again after clear");
  endtask

  initial begin
    bfm = new(axi);
    bfm.init();
    #(100ns);
    @(negedge clk_aon) rst_n = 1;
    aon_wait(5);
    case (test)
      "subsys_smoke":     test_smoke();
      "subsys_wdt_chain": test_wdt_chain();
      default: $fatal(1, "unknown test %s", test);
    endcase
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

  default clocking cb @(posedge clk_aon); endclocking
  c_rst:    cover property ($rose(rst_req));
  c_frz:    cover property ($rose(dut.freeze));
  c_ack:    cover property (dut.wdt_evt && dut.wdt_ack);
  for (genvar i = 0; i < 4; i++) begin : g_blk
    c_rd: cover property (axi.arvalid && axi.arready && axi.araddr[13:12] == 2'(i));
    c_wr: cover property (axi.awvalid && axi.awready && axi.awaddr[13:12] == 2'(i));
  end
endmodule
