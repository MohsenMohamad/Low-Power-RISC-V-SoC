// CPU subsystem (contents of power domain PD_CPU): RV32IM core, 4 KB I-cache,
// 4 KB write-back D-cache and a 2:1 AXI4-Lite mux to a single master port.
//
// Cacheable windows: (addr & MASK) == BASE. The defaults are the doc/SPEC.md
// address map (boot ROM 0x0000_0000 16 KB, RAM 0x1000_0000 128 KB); the SoC
// sets them explicitly from its own address-map parameters (pd_cpu).
//
// All inputs are synchronous to clk. Asynchronous SoC signals are synchronized
// once, in pd_cpu, before they reach this module (doc/CPU_SOC_INTERFACE.md).
`include "sva_macros.svh"
module cpu_top #(
  parameter logic [31:0] ROM_BASE = 32'h0000_0000,
  parameter logic [31:0] ROM_MASK = 32'hFFFF_C000,  // 16 KB
  parameter logic [31:0] RAM_BASE = 32'h1000_0000,
  parameter logic [31:0] RAM_MASK = 32'hFFFE_0000   // 128 KB
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] boot_addr_i,

  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [63:0] mtime_i,

  // Power handshake (doc/CPU_SOC_INTERFACE.md). All outputs are flop outputs.
  input  logic        idle_req_i,      // PMU requests quiescence (synchronized)
  output logic        idle_ack_o,      // in WFI, pipeline drained, no bus transaction
  output logic        core_sleep_o,    // in WFI, drained, no enabled interrupt pending
  output logic        cache_clean_o,   // D-cache holds no dirty line
  output logic        caches_idle_o,   // both caches idle (no bus transaction); status only

  // AXI4-Lite master
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_awaddr,
  output logic [2:0]  m_awprot,
  output logic        m_wvalid,
  input  logic        m_wready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_bvalid,
  output logic        m_bready,
  input  logic [1:0]  m_bresp,
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [2:0]  m_arprot,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,

  // Commit trace (verification)
  output logic        trace_valid_o,
  output logic        trace_irq_o,
  output logic        trace_trap_o,
  output logic [31:0] trace_pc_o,
  output logic [31:0] trace_insn_o,
  output logic [31:0] trace_next_pc_o,
  output logic [4:0]  trace_cause_o,
  output logic [31:0] trace_tval_o,
  output logic        trace_rd_we_o,
  output logic [4:0]  trace_rd_o,
  output logic [31:0] trace_rd_wdata_o,
  output logic        trace_mem_we_o,
  output logic        trace_mem_re_o,
  output logic [31:0] trace_mem_addr_o,
  output logic [31:0] trace_mem_wdata_o,
  output logic [3:0]  trace_mem_be_o,
  output logic [2:0]  trace_mip_o,

  // Debug observability (doc/CPU_SOC_INTERFACE.md "Debug observability",
  // doc/DEBUG_SPEC.md section 4). Flop outputs, one clk cycle after the event.
  output logic        dbg_ret_valid_o,   // one instruction retired (not trapped)
  output logic [31:0] dbg_ret_pc_o,
  output logic [31:0] dbg_ret_insn_o,
  output logic        dbg_trap_valid_o,  // a trap was taken (exception or interrupt)
  output logic [31:0] dbg_trap_cause_o,  // mcause written by the trap (bit 31 = interrupt)
  output logic [31:0] dbg_trap_pc_o,     // mepc written by the trap
  output logic [31:0] dbg_trap_tval_o,   // mtval written by the trap
  output logic        dbg_ic_hit_o,
  output logic        dbg_ic_miss_o,
  output logic        dbg_dc_hit_o,
  output logic        dbg_dc_miss_o,
  output logic        dbg_stall_o
);

  // Core <-> caches
  logic        ireq, ignt, irvalid, ierr;
  logic [31:0] iaddr, irdata;
  logic        dreq, dgnt, dwe, drvalid, derr;
  logic [3:0]  dbe;
  logic [31:0] daddr, dwdata, drdata;
  logic        dc_maint_req, dc_maint_inval, dc_maint_done, dc_wb_err;
  logic        ic_inval_req, ic_inval_done;
  logic        ic_idle, dc_idle, dc_clean;
  logic        core_sleep, wfi_quiet, wfi_hold;
  logic        idle_ack_q, core_sleep_q, mux_idle;
  logic        ic_ev_hit, ic_ev_miss, dc_ev_hit, dc_ev_miss, core_stall;

  // Cache AXI ports, [0] = I-cache, [1] = D-cache
  logic [1:0]       c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready;
  logic [1:0]       c_arvalid, c_arready, c_rvalid, c_rready;
  logic [1:0][31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
  logic [1:0][2:0]  c_awprot, c_arprot;
  logic [1:0][3:0]  c_wstrb;
  logic [1:0][1:0]  c_bresp, c_rresp;

  core_top u_core (
    .clk, .rst_n, .boot_addr_i,
    .imem_req_o (ireq), .imem_gnt_i (ignt), .imem_addr_o (iaddr),
    .imem_rvalid_i (irvalid), .imem_rdata_i (irdata), .imem_err_i (ierr),
    .dmem_req_o (dreq), .dmem_gnt_i (dgnt), .dmem_addr_o (daddr), .dmem_we_o (dwe),
    .dmem_be_o (dbe), .dmem_wdata_o (dwdata),
    .dmem_rvalid_i (drvalid), .dmem_rdata_i (drdata), .dmem_err_i (derr),
    .dc_maint_req_o (dc_maint_req), .dc_maint_inval_o (dc_maint_inval),
    .dc_maint_done_i (dc_maint_done), .dc_wb_err_i (dc_wb_err),
    .ic_inval_req_o (ic_inval_req), .ic_inval_done_i (ic_inval_done),
    .irq_software_i, .irq_timer_i, .irq_external_i, .mtime_i,
    .wfi_hold_i (wfi_hold), .core_sleep_o (core_sleep), .wfi_quiet_o (wfi_quiet), .stall_o (core_stall),
    .trace_valid_o, .trace_irq_o, .trace_trap_o, .trace_pc_o, .trace_insn_o,
    .trace_next_pc_o, .trace_cause_o, .trace_tval_o, .trace_rd_we_o, .trace_rd_o,
    .trace_rd_wdata_o, .trace_mem_we_o, .trace_mem_re_o, .trace_mem_addr_o,
    .trace_mem_wdata_o, .trace_mem_be_o, .trace_mip_o
  );

  icache #(
    .CACHE0_BASE (ROM_BASE), .CACHE0_MASK (ROM_MASK),
    .CACHE1_BASE (RAM_BASE), .CACHE1_MASK (RAM_MASK)
  ) u_icache (
    .clk, .rst_n,
    .req_i (ireq), .gnt_o (ignt), .addr_i (iaddr),
    .rvalid_o (irvalid), .rdata_o (irdata), .err_o (ierr),
    .inval_req_i (ic_inval_req), .inval_done_o (ic_inval_done),
    .m_awvalid (c_awvalid[0]), .m_awready (c_awready[0]), .m_awaddr (c_awaddr[0]), .m_awprot (c_awprot[0]),
    .m_wvalid  (c_wvalid[0]),  .m_wready  (c_wready[0]),  .m_wdata  (c_wdata[0]),  .m_wstrb  (c_wstrb[0]),
    .m_bvalid  (c_bvalid[0]),  .m_bready  (c_bready[0]),  .m_bresp  (c_bresp[0]),
    .m_arvalid (c_arvalid[0]), .m_arready (c_arready[0]), .m_araddr (c_araddr[0]), .m_arprot (c_arprot[0]),
    .m_rvalid  (c_rvalid[0]),  .m_rready  (c_rready[0]),  .m_rdata  (c_rdata[0]),  .m_rresp  (c_rresp[0]),
    .idle_o (ic_idle), .ev_hit_o (ic_ev_hit), .ev_miss_o (ic_ev_miss)
  );

  dcache #(
    .CACHE_BASE (RAM_BASE), .CACHE_MASK (RAM_MASK)
  ) u_dcache (
    .clk, .rst_n,
    .req_i (dreq), .gnt_o (dgnt), .addr_i (daddr), .we_i (dwe), .be_i (dbe), .wdata_i (dwdata),
    .rvalid_o (drvalid), .rdata_o (drdata), .err_o (derr),
    .maint_req_i (dc_maint_req), .maint_inval_i (dc_maint_inval),
    .maint_done_o (dc_maint_done), .wb_err_o (dc_wb_err), .cache_clean_o (dc_clean),
    .m_awvalid (c_awvalid[1]), .m_awready (c_awready[1]), .m_awaddr (c_awaddr[1]), .m_awprot (c_awprot[1]),
    .m_wvalid  (c_wvalid[1]),  .m_wready  (c_wready[1]),  .m_wdata  (c_wdata[1]),  .m_wstrb  (c_wstrb[1]),
    .m_bvalid  (c_bvalid[1]),  .m_bready  (c_bready[1]),  .m_bresp  (c_bresp[1]),
    .m_arvalid (c_arvalid[1]), .m_arready (c_arready[1]), .m_araddr (c_araddr[1]), .m_arprot (c_arprot[1]),
    .m_rvalid  (c_rvalid[1]),  .m_rready  (c_rready[1]),  .m_rdata  (c_rdata[1]),  .m_rresp  (c_rresp[1]),
    .idle_o (dc_idle), .ev_hit_o (dc_ev_hit), .ev_miss_o (dc_ev_miss)
  );

  axil_mux2 u_mux (
    .clk, .rst_n,
    .s_awvalid (c_awvalid), .s_awready (c_awready), .s_awaddr (c_awaddr), .s_awprot (c_awprot),
    .s_wvalid  (c_wvalid),  .s_wready  (c_wready),  .s_wdata  (c_wdata),  .s_wstrb  (c_wstrb),
    .s_bvalid  (c_bvalid),  .s_bready  (c_bready),  .s_bresp  (c_bresp),
    .s_arvalid (c_arvalid), .s_arready (c_arready), .s_araddr (c_araddr), .s_arprot (c_arprot),
    .s_rvalid  (c_rvalid),  .s_rready  (c_rready),  .s_rdata  (c_rdata),  .s_rresp  (c_rresp),
    .m_awvalid, .m_awready, .m_awaddr, .m_awprot, .m_wvalid, .m_wready, .m_wdata, .m_wstrb,
    .m_bvalid, .m_bready, .m_bresp, .m_arvalid, .m_arready, .m_araddr, .m_arprot,
    .m_rvalid, .m_rready, .m_rdata, .m_rresp,
    .idle_o (mux_idle)
  );

  assign caches_idle_o = ic_idle && dc_idle;

  // ---------------------------------------------------------------------------
  // PMU idle handshake (4-phase):
  //   idle_req 0->1 : ack once in WFI with the pipeline, fetch, both caches and
  //                   the bus mux idle (no outstanding AXI transaction).
  //   ack held      : while idle_req is high, even if an interrupt arrives; the
  //                   core does not leave WFI (wfi_hold) so it stays quiescent.
  //   idle_req 1->0 : ack drops the next cycle; WFI may then end on a wake.
  // The PMU may gate clk_cpu or remove power only while idle_ack is high.
  // ---------------------------------------------------------------------------
  logic quiescent;
  assign quiescent = wfi_quiet && ic_idle && dc_idle && mux_idle;
  assign wfi_hold  = idle_req_i || idle_ack_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idle_ack_q   <= 1'b0;
      core_sleep_q <= 1'b0;
    end else begin
      idle_ack_q   <= idle_req_i && (quiescent || idle_ack_q);
      core_sleep_q <= core_sleep && ic_idle && dc_idle && mux_idle;
    end
  end

  assign idle_ack_o    = idle_ack_q;
  assign core_sleep_o  = core_sleep_q;
  assign cache_clean_o = dc_clean;

  // ---------------------------------------------------------------------------
  // Debug observability (audit W21, B15). The commit trace above is a
  // verification port: trace_valid_o is also high for a trapped instruction
  // and for an interrupt entry, and the cause is 5 bits plus a separate
  // interrupt flag. The debug port converts it to the retire / trap contract
  // of doc/DEBUG_SPEC.md: a retire is a committed instruction that did not
  // trap; a trap is an exception (trace_trap_o) or an interrupt entry
  // (trace_irq_o) with the full 32-bit mcause. The core takes exceptions and
  // interrupts in different cycles (an interrupt only with the pipeline
  // drained), so retire and trap are never high together, and no retire can
  // follow a trap in the next cycle (the trap flushes the pipeline).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_ret_valid_o  <= 1'b0;
      dbg_ret_pc_o     <= '0;
      dbg_ret_insn_o   <= '0;
      dbg_trap_valid_o <= 1'b0;
      dbg_trap_cause_o <= '0;
      dbg_trap_pc_o    <= '0;
      dbg_trap_tval_o  <= '0;
      dbg_ic_hit_o     <= 1'b0;
      dbg_ic_miss_o    <= 1'b0;
      dbg_dc_hit_o     <= 1'b0;
      dbg_dc_miss_o    <= 1'b0;
      dbg_stall_o      <= 1'b0;
    end else begin
      dbg_ret_valid_o  <= trace_valid_o && !trace_trap_o && !trace_irq_o;
      dbg_ret_pc_o     <= trace_pc_o;
      dbg_ret_insn_o   <= trace_insn_o;
      dbg_trap_valid_o <= trace_trap_o || trace_irq_o;
      dbg_trap_cause_o <= {trace_irq_o, 26'd0, trace_cause_o};
      dbg_trap_pc_o    <= trace_pc_o;
      dbg_trap_tval_o  <= trace_tval_o;
      dbg_ic_hit_o     <= ic_ev_hit;
      dbg_ic_miss_o    <= ic_ev_miss;
      dbg_dc_hit_o     <= dc_ev_hit;
      dbg_dc_miss_o    <= dc_ev_miss;
      dbg_stall_o      <= core_stall;
    end
  end

  // An acknowledged core stays in WFI with no bus activity (SVA_ON builds).
  `SVA_ASSERT_IMP(a_ack_quiescent, clk, rst_n, idle_ack_q,
                  quiescent && !m_arvalid && !m_awvalid && !m_wvalid)

  // Debug port contract (doc/DEBUG_SPEC.md 4.2).
  `SVA_ASSERT(a_dbg_ret_trap_excl, clk, rst_n, !(dbg_ret_valid_o && dbg_trap_valid_o))
  `SVA_ASSERT_NXT(a_dbg_no_ret_after_trap, clk, rst_n, dbg_trap_valid_o, !dbg_ret_valid_o)
  `SVA_ASSERT(a_dbg_ic_excl, clk, rst_n, !(dbg_ic_hit_o && dbg_ic_miss_o))
  `SVA_ASSERT(a_dbg_dc_excl, clk, rst_n, !(dbg_dc_hit_o && dbg_dc_miss_o))
endmodule
