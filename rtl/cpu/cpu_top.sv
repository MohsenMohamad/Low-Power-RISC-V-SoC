// CPU subsystem (contents of power domain PD_CPU): RV32IM core, 4 KB I-cache,
// 4 KB write-back D-cache and a 2:1 AXI4-Lite mux to a single master port.
module cpu_top #(
  parameter logic [31:0] ROM_BASE = 32'h0000_0000,
  parameter logic [31:0] ROM_MASK = 32'hFFFF_C000,  // 16 KB
  parameter logic [31:0] RAM_BASE = 32'h8000_0000,
  parameter logic [31:0] RAM_MASK = 32'hFFFE_0000   // 128 KB
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] boot_addr_i,

  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [63:0] mtime_i,

  output logic        core_sleep_o,
  output logic        caches_idle_o,

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
  output logic [2:0]  trace_mip_o
);

  // Core <-> caches
  logic        ireq, ignt, irvalid, ierr;
  logic [31:0] iaddr, irdata;
  logic        dreq, dgnt, dwe, drvalid, derr;
  logic [3:0]  dbe;
  logic [31:0] daddr, dwdata, drdata;
  logic        dc_maint_req, dc_maint_inval, dc_maint_done, dc_wb_err;
  logic        ic_inval_req, ic_inval_done;
  logic        ic_idle, dc_idle;

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
    .core_sleep_o,
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
    .idle_o (ic_idle)
  );

  dcache #(
    .CACHE_BASE (RAM_BASE), .CACHE_MASK (RAM_MASK)
  ) u_dcache (
    .clk, .rst_n,
    .req_i (dreq), .gnt_o (dgnt), .addr_i (daddr), .we_i (dwe), .be_i (dbe), .wdata_i (dwdata),
    .rvalid_o (drvalid), .rdata_o (drdata), .err_o (derr),
    .maint_req_i (dc_maint_req), .maint_inval_i (dc_maint_inval),
    .maint_done_o (dc_maint_done), .wb_err_o (dc_wb_err),
    .m_awvalid (c_awvalid[1]), .m_awready (c_awready[1]), .m_awaddr (c_awaddr[1]), .m_awprot (c_awprot[1]),
    .m_wvalid  (c_wvalid[1]),  .m_wready  (c_wready[1]),  .m_wdata  (c_wdata[1]),  .m_wstrb  (c_wstrb[1]),
    .m_bvalid  (c_bvalid[1]),  .m_bready  (c_bready[1]),  .m_bresp  (c_bresp[1]),
    .m_arvalid (c_arvalid[1]), .m_arready (c_arready[1]), .m_araddr (c_araddr[1]), .m_arprot (c_arprot[1]),
    .m_rvalid  (c_rvalid[1]),  .m_rready  (c_rready[1]),  .m_rdata  (c_rdata[1]),  .m_rresp  (c_rresp[1]),
    .idle_o (dc_idle)
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
    .m_rvalid, .m_rready, .m_rdata, .m_rresp
  );

  assign caches_idle_o = ic_idle && dc_idle;

endmodule
