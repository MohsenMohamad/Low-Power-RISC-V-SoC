// -----------------------------------------------------------------------------
// pd_cpu - PD_CPU power-domain boundary (switchable, clk_cpu)
//
// Everything instantiated below this module belongs to PD_CPU in the UPF
// (create_power_domain PD_CPU -elements {u_pd_cpu}). All outputs are isolated
// in the parent (PD_AON) by tech_iso cells; inputs need no isolation.
//
// Contents: the in-house RV32IM core with its I-cache, write-back D-cache and
// AXI4-Lite mux (cpu_top), plus the CPU-boundary crossings:
//   * meip/mtip/msip and idle_req (asynchronous, clk_aon) are synchronized
//     here, exactly once (u_async_sync). Nothing inside cpu_top synchronizes
//     them again, and nothing in PD_AON synchronizes them on their way here.
//   * mtime (64 bit, clk_aon) arrives as a coherent snapshot through a
//     four-phase handshake (cdc_snapshot_dst); the source half is in soc_top.
// The port list, widths, clock domains and handshakes are specified in
// doc/CPU_SOC_INTERFACE.md.
// -----------------------------------------------------------------------------
module pd_cpu #(
  parameter logic [31:0] BOOT_ADDR = 32'h0000_0000,
  parameter logic [31:0] ROM_BASE  = 32'h0000_0000,
  parameter logic [31:0] ROM_MASK  = 32'hFFFF_C000,
  parameter logic [31:0] RAM_BASE  = 32'h1000_0000,
  parameter logic [31:0] RAM_MASK  = 32'hFFFE_0000
) (
  input  logic        clk_i,          // clk_cpu (gated DVFS clock)
  input  logic        rst_ni,         // async assert, released synchronous to clk_cpu_root
  // interrupts and power handshake from PD_AON (asynchronous to clk_i)
  input  logic        meip_i,
  input  logic        mtip_i,
  input  logic        msip_i,
  input  logic        idle_req_i,
  output wire         idle_ack_o,
  output wire         core_sleep_o,
  output wire         cache_clean_o,
  // mtime snapshot crossing
  input  logic [63:0] mtime_snap_i,   // quasi-static, clk_aon
  input  logic        mtime_ack_i,    // 4-phase acknowledge, clk_aon
  output wire         mtime_req_o,    // 4-phase request, clk_cpu
  // AXI4-Lite master (clk_cpu; crosses to clk_aon in the PD_AON bridge)
  output wire         m_awvalid_o,
  input  logic        m_awready_i,
  output wire  [31:0] m_awaddr_o,
  output wire  [2:0]  m_awprot_o,
  output wire         m_wvalid_o,
  input  logic        m_wready_i,
  output wire  [31:0] m_wdata_o,
  output wire  [3:0]  m_wstrb_o,
  input  logic        m_bvalid_i,
  output wire         m_bready_o,
  input  logic [1:0]  m_bresp_i,
  output wire         m_arvalid_o,
  input  logic        m_arready_i,
  output wire  [31:0] m_araddr_o,
  output wire  [2:0]  m_arprot_o,
  input  logic        m_rvalid_i,
  output wire         m_rready_o,
  input  logic [31:0] m_rdata_i,
  input  logic [1:0]  m_rresp_i
);
  // ---------------- the single synchronization point ----------------
  logic meip_s, mtip_s, msip_s, idle_req_s;
  tech_sync #(.WIDTH(4), .STAGES(2)) u_async_sync (
    .clk_i, .rst_ni,
    .d_i ({idle_req_i, msip_i, mtip_i, meip_i}),
    .q_o ({idle_req_s, msip_s, mtip_s, meip_s})
  );

  // ---------------- mtime ----------------
  logic [63:0] mtime;
  logic        mtime_valid;
  cdc_snapshot_dst #(.W(64)) u_mtime_dst (
    .clk_i, .rst_ni, .snap_i (mtime_snap_i), .ack_i (mtime_ack_i),
    .req_o (mtime_req_o), .value_o (mtime), .valid_o (mtime_valid)
  );

  // ---------------- CPU core + caches ----------------
  /* verilator lint_off PINCONNECTEMPTY */
  cpu_top #(
    .ROM_BASE (ROM_BASE), .ROM_MASK (ROM_MASK), .RAM_BASE (RAM_BASE), .RAM_MASK (RAM_MASK)
  ) u_cpu (
    .clk (clk_i), .rst_n (rst_ni), .boot_addr_i (BOOT_ADDR),
    .irq_software_i (msip_s), .irq_timer_i (mtip_s), .irq_external_i (meip_s),
    .mtime_i (mtime),
    .idle_req_i (idle_req_s), .idle_ack_o, .core_sleep_o, .cache_clean_o,
    .caches_idle_o (),
    .m_awvalid (m_awvalid_o), .m_awready (m_awready_i), .m_awaddr (m_awaddr_o), .m_awprot (m_awprot_o),
    .m_wvalid  (m_wvalid_o),  .m_wready  (m_wready_i),  .m_wdata  (m_wdata_o),  .m_wstrb  (m_wstrb_o),
    .m_bvalid  (m_bvalid_i),  .m_bready  (m_bready_o),  .m_bresp  (m_bresp_i),
    .m_arvalid (m_arvalid_o), .m_arready (m_arready_i), .m_araddr (m_araddr_o), .m_arprot (m_arprot_o),
    .m_rvalid  (m_rvalid_i),  .m_rready  (m_rready_o),  .m_rdata  (m_rdata_i),  .m_rresp  (m_rresp_i),
    .trace_valid_o (), .trace_irq_o (), .trace_trap_o (), .trace_pc_o (), .trace_insn_o (),
    .trace_next_pc_o (), .trace_cause_o (), .trace_tval_o (), .trace_rd_we_o (), .trace_rd_o (),
    .trace_rd_wdata_o (), .trace_mem_we_o (), .trace_mem_re_o (), .trace_mem_addr_o (),
    .trace_mem_wdata_o (), .trace_mem_be_o (), .trace_mip_o ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic unused;
  assign unused = mtime_valid;
endmodule
