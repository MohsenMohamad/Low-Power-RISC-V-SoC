// Integration preview: Session 3's PicoRV32 bring-up SoC (platform/picorv32,
// used unmodified) + the debug subsystem (rtl/debug) on the SoC external
// port, so the debug firmware and the bench run against real RTL now.
// [MERGE] replaced by Session 2's SoC top with the debug blocks on the AXI
// interconnect at DBG_BASE and the ports wired as in doc/DEBUG_SPEC.md.
//
// External port map (0x4F00_0000 + ext_addr):
//   0x0000-0x00FF  simulation control (Session 3 layout + debug extension)
//     0x00 EXIT  0x04 ARG  0x08 PUTC  0x0C TIME
//     0x10 SEED  0x14 FLAGS  0x18 ITERS  0x1C DBG_MAGIC (0xDB6B0C5E)
//   0x4000-0x7FFF  dbg_subsys (16 KB) -> firmware DBG_BASE = 0x4F00_4000
//
// Testbench glue (not part of the design; see DEBUG_SPEC section 14):
//   * CPU retire / trap port, cache events and stall are tapped from the
//     PicoRV32 core and its caches (RVFI-equivalent internal signals) and
//     isolated (forced to 0) while the PMU isolates PD_CPU.
//   * pwr_state / dvfs_op / PMU events are derived from the PMU FSM.
//   * dbg_wdt cpu_rst_req_o is applied as a PMU software reset (the PicoRV32
//     SoC has no external PD_CPU reset input).
//
// Plusargs: +rom_hex +ram_hex +test=<id> +seed=<n> +flags=<n> +iters=<n>
//           +monitor  +uart_log=<f>  +timeout=<aon cycles>  +pty +pty_file=<f>
module tb_dbg_soc;
  timeunit 1ns; timeprecision 1ps;
  /* verilator lint_off BLKSEQ */
  localparam int UART_DIV = 8;

  logic clk_aon = 1'b0, clk_ref = 1'b0, por_n = 1'b0;
  always #15.5 clk_aon = ~clk_aon;     // ~32.3 MHz (as Session 3's testbench)
  always #5.0  clk_ref = ~clk_ref;     // 100 MHz

  logic        uart_rxd, uart_txd;
  logic        ext_req, ext_we;
  logic [15:0] ext_addr;
  logic [31:0] ext_wdata, ext_rdata;
  logic        cpu_trap, cpu_pwr, cpu_iso, ram_ret;

  pico_soc #(.UART_DIV(16'(UART_DIV))) dut (
    .clk_aon(clk_aon), .clk_ref(clk_ref), .por_n(por_n),
    .uart_rxd(uart_rxd), .uart_txd(uart_txd),
    .ext_req(ext_req), .ext_we(ext_we), .ext_addr(ext_addr),
    .ext_wdata(ext_wdata), .ext_rdata(ext_rdata),
    .cpu_trap(cpu_trap), .cpu_pwr(cpu_pwr), .cpu_iso(cpu_iso), .ram_ret(ram_ret));

  // ---------------- configuration ----------------
  longint unsigned cycles = 0, timeout = 64'd200_000_000;
  logic [31:0] arg, seed = 1, flags = 0, iters = 0;
  integer log_fd = 0;
  initial begin
    string s;
    int unsigned t;
    arg = 32'h8000_FFFF;
    if ($value$plusargs("test=%d", t)) arg[15:0] = t[15:0];
    if ($test$plusargs("monitor")) arg[30] = 1'b1;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("flags=%d", flags));
    void'($value$plusargs("iters=%d", iters));
    void'($value$plusargs("timeout=%d", timeout));
    if ($value$plusargs("uart_log=%s", s)) log_fd = $fopen(s, "w");
    $display("[TB] integration preview: test=%0d seed=%0d flags=%0d iters=%0d monitor=%0d",
             arg[15:0], seed, flags, iters, arg[30]);
    #200 por_n = 1'b1;
  end

  always_ff @(posedge clk_aon) begin
    cycles <= cycles + 1;
    if (cycles == timeout) begin
      $display("\n[TB] TIMEOUT after %0d clk_aon cycles", cycles);
      finish_sim(32'hDEAD_0001);
    end
  end

  task automatic finish_sim(input logic [31:0] code);
    if (code == 0) $display("[TB] SIM RESULT: PASS (cycles=%0d)", cycles);
    else           $display("[TB] SIM RESULT: FAIL code=0x%08x (cycles=%0d)", code, cycles);
    if (log_fd != 0) $fclose(log_fd);
    $finish;
  endtask

  // ---------------- debug subsystem on the external port ----------------
  wire dbg_sel = ext_addr[15:14] == 2'b01;
  logic        d_awready, d_wready, d_bvalid, d_arready, d_rvalid;
  logic [1:0]  d_bresp, d_rresp;
  logic [31:0] d_rdata;
  logic        rst_req, wdt_irq, err_irq;

  // CPU-side observation (testbench taps, isolated while PD_CPU is isolated)
  wire         iso = dut.iso_en;
  logic        ret_valid, trap_valid, irq_active_q;
  logic [31:0] ret_pc, ret_insn, trap_cause, trap_pc;
  always_comb begin
    ret_valid = !iso && dut.u_pd_cpu.u_core.resetn && dut.u_pd_cpu.u_core.dbg_valid_insn &&
                dut.u_pd_cpu.u_core.launch_next_insn;
    ret_pc    = iso ? 32'd0 : dut.u_pd_cpu.u_core.dbg_insn_addr;
    ret_insn  = iso ? 32'd0 : dut.u_pd_cpu.u_core.dbg_insn_opcode;
  end
  // PicoRV32 IRQ entry -> trap port: eoi (pending bits being served) is set
  // one IRQ-entry step after irq_active, so the trap is reported when eoi
  // goes from 0 to non-zero.
  // bit 1 ecall/ebreak/illegal -> cause 2, bit 2 misaligned/bus error -> 4,
  // bit 3 MTIP, bit 4 MSIP, bit 5 MEIP (Session 3 IRQ map) -> interrupts.
  logic [31:0] eoi_q = '0;
  always_ff @(posedge dut.clk_cpu) begin
    irq_active_q <= dut.u_pd_cpu.u_core.irq_active;
    eoi_q        <= dut.u_pd_cpu.u_core.eoi;
  end
  always_comb begin
    automatic logic [31:0] e = dut.u_pd_cpu.u_core.eoi;
    trap_valid = !iso && e != 0 && eoi_q == 0;
    trap_cause = e[1] ? 32'd2 : e[2] ? 32'd4 : e[3] ? 32'h8000_0007 : e[4] ? 32'h8000_0003 : 32'h8000_000B;
    trap_pc    = dut.u_pd_cpu.u_core.dbg_insn_addr;
  end
  bit dbg_taps = 1'b0;
  initial dbg_taps = $test$plusargs("dbg_taps");
  always @(posedge dut.clk_cpu)
    if (dbg_taps && (trap_valid || dut.u_pd_cpu.u_core.irq_active != irq_active_q))
      $display("[TB] %0t trap_valid=%0d irq_active=%0d eoi=%08x cause=%08x pc=%08x", $time, trap_valid,
               dut.u_pd_cpu.u_core.irq_active, dut.u_pd_cpu.u_core.eoi, trap_cause, trap_pc);
  wire ic_hit  = !iso && dut.u_pd_cpu.i_hit;
  wire ic_miss = !iso && dut.u_pd_cpu.i_miss;
  wire dc_hit  = !iso && dut.u_pd_cpu.d_hit;
  wire dc_miss = !iso && dut.u_pd_cpu.d_miss;
  wire stall   = !iso && dut.u_pd_cpu.u_core.mem_valid && !dut.u_pd_cpu.u_core.mem_ready;

  // Power state from the PMU FSM (enum order of aon_pmu.pst_t)
  logic [1:0] pstate, pstate_q = 2'd0, off_kind = 2'd2;
  logic [31:0] abort_q = 0;
  logic        pmu_evt;
  logic [1:0]  pmu_from, pmu_to, pmu_res;
  always_comb begin
    automatic int s = int'(dut.u_pmu.st);
    if (s == 1 || s == 17)       pstate = 2'd0;          // RUN, SWRST_WAIT
    else if (s >= 2 && s <= 7)   pstate = 2'd1;          // clock gated / DVFS
    else                         pstate = off_kind;      // power-down / off / wake-up / POR
  end
  always_ff @(posedge clk_aon) begin
    if (int'(dut.u_pmu.st) == 8) off_kind <= (dut.u_pmu.mode == 2'd2) ? 2'd3 : 2'd2;   // P_ISO
    pstate_q <= pstate;
    abort_q  <= dut.u_pmu.cnt_abort;
  end
  always_comb begin
    pmu_evt  = (pstate != pstate_q) || (dut.u_pmu.cnt_abort != abort_q && dut.u_pmu.cnt_abort != 0);
    pmu_from = pstate_q;
    pmu_to   = pstate;
    pmu_res  = (dut.u_pmu.cnt_abort != abort_q && dut.u_pmu.cnt_abort != 0) ? 2'd2 : 2'd0;
  end

  dbg_subsys #(.TRACE_DEPTH(64)) u_dbg (
    .clk_aon_i(clk_aon), .rst_aon_ni(por_n), .clk_cpu_i(dut.clk_cpu),
    .s_axil_awaddr(ext_addr[13:0]), .s_axil_awprot(3'd0), .s_axil_awvalid(ext_req && ext_we && dbg_sel),
    .s_axil_awready(d_awready), .s_axil_wdata(ext_wdata), .s_axil_wstrb(4'hF),
    .s_axil_wvalid(ext_req && ext_we && dbg_sel), .s_axil_wready(d_wready),
    .s_axil_bresp(d_bresp), .s_axil_bvalid(d_bvalid), .s_axil_bready(1'b1),
    .s_axil_araddr(ext_addr[13:0]), .s_axil_arprot(3'd0), .s_axil_arvalid(ext_req && !ext_we && dbg_sel),
    .s_axil_arready(d_arready), .s_axil_rdata(d_rdata), .s_axil_rresp(d_rresp), .s_axil_rvalid(d_rvalid),
    .s_axil_rready(1'b1),
    .ret_valid_i(ret_valid), .ret_pc_i(ret_pc), .ret_insn_i(ret_insn),
    .trap_valid_i(trap_valid), .trap_cause_i(trap_cause), .trap_pc_i(trap_pc), .trap_tval_i(32'd0),
    .ic_hit_i(ic_hit), .ic_miss_i(ic_miss), .dc_hit_i(dc_hit), .dc_miss_i(dc_miss), .stall_i(stall),
    .pwr_state_i(pstate), .dvfs_op_i(dut.u_pmu.cur_op), .pmu_evt_valid_i(pmu_evt),
    .pmu_evt_from_i(pmu_from), .pmu_evt_to_i(pmu_to), .pmu_evt_result_i(pmu_res),
    .cpu_rst_req_o(rst_req), .wdt_irq_o(wdt_irq), .err_irq_o(err_irq));

  // the external port has no wait states: the debug blocks must accept
  // every strobe immediately and answer in the next cycle
  a_ext_ready: assert property (@(posedge clk_aon) disable iff (!por_n)
    ext_req && dbg_sel |-> (ext_we ? (d_awready && d_wready) : d_arready));
  a_ext_resp:  assert property (@(posedge clk_aon) disable iff (!por_n)
    ext_req && dbg_sel && !ext_we |=> d_rvalid);

  // ---------------- watchdog reset -> PMU software reset (glue) ----------------
  logic rst_req_q = 1'b0, swrst_go = 1'b0;
  int unsigned n_wdt_resets = 0;
  always_ff @(posedge clk_aon) begin
    rst_req_q <= rst_req;
    if (rst_req && !rst_req_q) begin
      n_wdt_resets++;
      $display("\n[TB] watchdog PD_CPU reset request -> PMU software reset (PMU state %0d)", int'(dut.u_pmu.st));
    end
  end
  always @(negedge clk_aon) begin
    if (rst_req && !rst_req_q && !swrst_go) begin
      swrst_go = 1'b1;
      force dut.u_pmu.req = 1'b1; force dut.u_pmu.we = 1'b1;
      force dut.u_pmu.addr = 12'h01C; force dut.u_pmu.wdata = 32'h5AFE_0001;
    end else if (swrst_go) begin
      swrst_go = 1'b0;
      release dut.u_pmu.req; release dut.u_pmu.we; release dut.u_pmu.addr; release dut.u_pmu.wdata;
    end
  end

  // ---------------- simulation control device ----------------
  logic [31:0] ctl_rdata = '0;
  always_ff @(posedge clk_aon) begin
    if (ext_req && ext_we && !dbg_sel) begin
      unique case (ext_addr[7:0])
        8'h00: finish_sim(ext_wdata);
        8'h08: $write("%c", ext_wdata[7:0]);
        default: ;
      endcase
    end
    if (ext_req && !ext_we) begin
      unique case (ext_addr[7:0])
        8'h04:   ctl_rdata <= arg;
        8'h0C:   ctl_rdata <= cycles[31:0];
        8'h10:   ctl_rdata <= seed;
        8'h14:   ctl_rdata <= flags;
        8'h18:   ctl_rdata <= iters;
        8'h1C:   ctl_rdata <= 32'hDB6B_0C5E;
        default: ctl_rdata <= 32'd0;
      endcase
    end
  end
  logic dbg_rd_q = 1'b0;
  always_ff @(posedge clk_aon) dbg_rd_q <= ext_req && dbg_sel;
  assign ext_rdata = dbg_rd_q ? d_rdata : ctl_rdata;

  always_ff @(posedge clk_aon) begin
    if (por_n && cpu_trap) begin
      $display("\n[TB] CPU entered TRAP state (unrecoverable exception)");
      finish_sim(32'hDEAD_0002);
    end
  end

  // ---------------- UART: console log + pseudo-terminal bridge ----------------
  typedef enum logic [1:0] {T_IDLE, T_START, T_DATA, T_STOP} tst_t;
  tst_t        tst = T_IDLE;
  int unsigned tcnt = 0, tbit = 0;
  logic [7:0]  tsh;
  always_ff @(posedge clk_aon) begin
    unique case (tst)
      T_IDLE:  if (!uart_txd) begin tst <= T_START; tcnt <= 0; end
      T_START: if (tcnt == UART_DIV / 2 - 1) begin tcnt <= 0; tbit <= 0; tst <= uart_txd ? T_IDLE : T_DATA; end
               else tcnt <= tcnt + 1;
      T_DATA:  if (tcnt == UART_DIV - 1) begin
                 tcnt <= 0; tsh <= {uart_txd, tsh[7:1]};
                 if (tbit == 7) tst <= T_STOP; else tbit <= tbit + 1;
               end else tcnt <= tcnt + 1;
      T_STOP:  if (tcnt == UART_DIV - 1) begin
                 tcnt <= 0; tst <= T_IDLE;
                 $write("%c", tsh);
                 if (log_fd != 0) $fwrite(log_fd, "%c", tsh);
               end else tcnt <= tcnt + 1;
      default: tst <= T_IDLE;
    endcase
  end

  dbg_uart_pty_bridge #(.DIV(UART_DIV)) u_pty (.clk(clk_aon), .uart_txd(uart_txd), .uart_rxd(uart_rxd));
  /* verilator lint_on BLKSEQ */
endmodule
