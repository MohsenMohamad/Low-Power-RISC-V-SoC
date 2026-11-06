// -----------------------------------------------------------------------------
// aon_subsys - always-on subsystem (PD_AON, clk_aon)
//
// AXI4-Lite interconnect and all always-on slaves (doc/SPEC.md address map;
// bases of ROM / RAM / RAM alias are parameters set by soc_top):
//   0x0000_0000  boot ROM      16 KB
//   0x1000_0000  main RAM     128 KB (retention capable)
//   0x2000_0000  UART
//   0x2000_1000  machine timer (mtime/mtimecmp/msip)
//   0x2000_2000  interrupt controller
//   0x2000_3000  PMU
//   0x2000_4000  wake timer
//   0x2000_8000  debug blocks (dbg_subsys, 16 KB decoded: trace, event counters,
//                error log, watchdog; 0x2000_C000-0x2000_FFFF of the 32 KB debug
//                range is unmapped -> SLVERR; doc/DEBUG_SPEC.md)
//   0x3000_0000  RAM uncached alias 128 KB: same physical RAM as 0x1000_0000.
//                Not cacheable in the CPU (outside the D-cache window), so
//                accesses bypass the D-cache. The alias is folded onto the RAM
//                window before the interconnect decode.
// Unmapped addresses return SLVERR.
// Interrupt controller sources:
//   0 UART, 1 wake timer, 2 PMU (DVFS done), 3 external wake pin,
//   4 debug error log, 5 watchdog bark, 7:6 spare
// -----------------------------------------------------------------------------
module aon_subsys #(
  parameter ROM_INIT       = "",
  parameter int    VSETTLE_CYCLES = 8,
  parameter int    RET_CYCLES     = 4,
  parameter int    ISO_CYCLES     = 2,
  parameter int    RST_CLK_CYCLES = 4,
  parameter logic [1:0] RESET_OP  = 2'd2,
  parameter logic [31:0] ROM_BASE       = 32'h0000_0000,
  parameter logic [31:0] ROM_MASK       = 32'hFFFF_C000,
  parameter logic [31:0] RAM_BASE       = 32'h1000_0000,
  parameter logic [31:0] RAM_MASK       = 32'hFFFE_0000,
  parameter logic [31:0] RAM_ALIAS_BASE = 32'h3000_0000,
  parameter int unsigned TRACE_DEPTH    = 64
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // AXI4-Lite slave port (from the CDC bridge)
  input  logic        s_awvalid_i,
  output logic        s_awready_o,
  input  logic [31:0] s_awaddr_i,
  input  logic [2:0]  s_awprot_i,
  input  logic        s_wvalid_i,
  output logic        s_wready_o,
  input  logic [31:0] s_wdata_i,
  input  logic [3:0]  s_wstrb_i,
  output logic        s_bvalid_o,
  input  logic        s_bready_i,
  output logic [1:0]  s_bresp_o,
  input  logic        s_arvalid_i,
  output logic        s_arready_o,
  input  logic [31:0] s_araddr_i,
  input  logic [2:0]  s_arprot_i,
  output logic        s_rvalid_o,
  input  logic        s_rready_i,
  output logic [31:0] s_rdata_o,
  output logic [1:0]  s_rresp_o,
  // pins
  input  logic        uart_rx_i,
  output logic        uart_tx_o,
  input  logic        ext_wake_i,     // asynchronous
  // interrupts to the CPU
  output logic        meip_o,
  output logic        mtip_o,
  output logic        msip_o,
  output logic [63:0] mtime_o,
  // PMU <-> PD_CPU control (already synchronized / isolated)
  input  logic        core_sleep_i,
  input  logic        idle_ack_i,
  input  logic        cache_clean_i,
  output logic        idle_req_o,
  output logic        cg_en_o,
  input  logic        cg_ack_i,
  input  logic        bus_idle_i,
  output logic        iso_en_o,
  output logic        cpu_rst_no,
  input  logic        cpu_rst_ack_i,
  output logic        pwr_sw_en_o,
  input  logic        pwr_good_i,
  output logic [1:0]  dvfs_sel_o,
  input  logic [2:0]  dvfs_active_i,
  output logic [1:0]  vsel_o,
  output logic [4:0]  pmu_state_o,
  // debug observability from PD_CPU (clk_cpu, already isolated: 0 while off)
  input  logic        clk_cpu_i,
  input  logic        dbg_ret_valid_i,
  input  logic [31:0] dbg_ret_pc_i,
  input  logic [31:0] dbg_ret_insn_i,
  input  logic        dbg_trap_valid_i,
  input  logic [31:0] dbg_trap_cause_i,
  input  logic [31:0] dbg_trap_pc_i,
  input  logic [31:0] dbg_trap_tval_i,
  input  logic        dbg_ic_hit_i,
  input  logic        dbg_ic_miss_i,
  input  logic        dbg_dc_hit_i,
  input  logic        dbg_dc_miss_i,
  input  logic        dbg_stall_i
);
  localparam int NS = 8;
  localparam int RAW = 17;
  localparam logic [NS*32-1:0] BASE = {
    32'h2000_8000, 32'h2000_4000, 32'h2000_3000, 32'h2000_2000, 32'h2000_1000,
    32'h2000_0000, RAM_BASE, ROM_BASE};
  localparam logic [NS*32-1:0] MASK = {
    32'hFFFF_C000, 32'hFFFF_F000, 32'hFFFF_F000, 32'hFFFF_F000, 32'hFFFF_F000,
    32'hFFFF_F000, RAM_MASK, ROM_MASK};

  // ---------------- RAM uncached alias ----------------
  // An address in the alias window is replaced by the same offset in the RAM
  // window; the decoder then routes it to the one physical RAM.
  function automatic logic [31:0] fold_alias(input logic [31:0] a);
    if ((a & RAM_MASK) == RAM_ALIAS_BASE) return RAM_BASE | (a & ~RAM_MASK);
    return a;
  endfunction
  logic [31:0] x_awaddr, x_araddr;
  assign x_awaddr = fold_alias(s_awaddr_i);
  assign x_araddr = fold_alias(s_araddr_i);

  localparam int S_ROM = 0, S_RAM = 1, S_UART = 2, S_MTIMER = 3,
                 S_INTC = 4, S_PMU = 5, S_WTIMER = 6, S_DBG = 7;
  localparam int NR = 7;   // slaves behind axil_reg_slave (all but the debug blocks)

  // ---------------- interconnect ----------------
  logic [NS-1:0]    m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [NS-1:0]    m_arvalid, m_arready, m_rvalid, m_rready;
  logic [31:0]      m_awaddr, m_wdata, m_araddr;
  logic [2:0]       m_awprot, m_arprot;
  logic [3:0]       m_wstrb;
  logic [NS*2-1:0]  m_bresp, m_rresp;
  logic [NS*32-1:0] m_rdata;

  axil_demux #(.N(NS), .BASE(BASE), .MASK(MASK)) u_xbar (
    .clk_i, .rst_ni,
    .s_awvalid_i, .s_awready_o, .s_awaddr_i (x_awaddr), .s_awprot_i,
    .s_wvalid_i, .s_wready_o, .s_wdata_i, .s_wstrb_i,
    .s_bvalid_o, .s_bready_i, .s_bresp_o,
    .s_arvalid_i, .s_arready_o, .s_araddr_i (x_araddr), .s_arprot_i,
    .s_rvalid_o, .s_rready_i, .s_rdata_o, .s_rresp_o,
    .m_awvalid_o (m_awvalid), .m_awready_i (m_awready), .m_awaddr_o (m_awaddr), .m_awprot_o (m_awprot),
    .m_wvalid_o (m_wvalid), .m_wready_i (m_wready), .m_wdata_o (m_wdata), .m_wstrb_o (m_wstrb),
    .m_bvalid_i (m_bvalid), .m_bready_o (m_bready), .m_bresp_i (m_bresp),
    .m_arvalid_o (m_arvalid), .m_arready_i (m_arready), .m_araddr_o (m_araddr), .m_arprot_o (m_arprot),
    .m_rvalid_i (m_rvalid), .m_rready_o (m_rready), .m_rdata_i (m_rdata), .m_rresp_i (m_rresp)
  );

  logic unused_prot;
  assign unused_prot = ^{m_awprot, m_arprot};

  // ---------------- register request ports ----------------
  logic [NR-1:0]    req, we, ack, err;
  logic [RAW-1:0]   addr  [NR];
  logic [31:0]      wdata [NR];
  logic [3:0]       wstrb [NR];
  logic [31:0]      rdata [NR];

  for (genvar i = 0; i < NR; i++) begin : g_slv
    axil_reg_slave #(.AW(RAW)) u_slv (
      .clk_i, .rst_ni,
      .s_awvalid_i (m_awvalid[i]), .s_awready_o (m_awready[i]), .s_awaddr_i (m_awaddr),
      .s_wvalid_i (m_wvalid[i]), .s_wready_o (m_wready[i]), .s_wdata_i (m_wdata), .s_wstrb_i (m_wstrb),
      .s_bvalid_o (m_bvalid[i]), .s_bready_i (m_bready[i]), .s_bresp_o (m_bresp[2*i +: 2]),
      .s_arvalid_i (m_arvalid[i]), .s_arready_o (m_arready[i]), .s_araddr_i (m_araddr),
      .s_rvalid_o (m_rvalid[i]), .s_rready_i (m_rready[i]), .s_rdata_o (m_rdata[32*i +: 32]),
      .s_rresp_o (m_rresp[2*i +: 2]),
      .req_o (req[i]), .we_o (we[i]), .addr_o (addr[i]), .wdata_o (wdata[i]), .wstrb_o (wstrb[i]),
      .ack_i (ack[i]), .rdata_i (rdata[i]), .err_i (err[i])
    );
  end

  // ---------------- memories ----------------
  logic ram_ret;

  aon_mem #(.IS_ROM(1'b1), .BYTES(16384), .INIT_FILE(ROM_INIT)) u_rom (
    .clk_i, .rst_ni, .ret_i (1'b0),
    .req_i (req[S_ROM]), .we_i (we[S_ROM]), .addr_i (addr[S_ROM][13:0]),
    .wdata_i (wdata[S_ROM]), .wstrb_i (wstrb[S_ROM]),
    .ack_o (ack[S_ROM]), .rdata_o (rdata[S_ROM]), .err_o (err[S_ROM])
  );

  aon_mem #(.IS_ROM(1'b0), .BYTES(131072)) u_ram (
    .clk_i, .rst_ni, .ret_i (ram_ret),
    .req_i (req[S_RAM]), .we_i (we[S_RAM]), .addr_i (addr[S_RAM][16:0]),
    .wdata_i (wdata[S_RAM]), .wstrb_i (wstrb[S_RAM]),
    .ack_o (ack[S_RAM]), .rdata_o (rdata[S_RAM]), .err_o (err[S_RAM])
  );

  // ---------------- peripherals ----------------
  logic       uart_irq, wtimer_irq, pmu_irq, ext_wake_s;
  logic [1:0] dbg_pstate, dbg_op, dbg_evt_from, dbg_evt_to, dbg_evt_result;
  logic       dbg_evt_valid, dbg_wdt_rst_req, dbg_wdt_irq, dbg_err_irq;
  logic [7:0] irq_src;

  aon_uart u_uart (
    .clk_i, .rst_ni, .rx_i (uart_rx_i), .tx_o (uart_tx_o), .irq_o (uart_irq),
    .req_i (req[S_UART]), .we_i (we[S_UART]), .addr_i (addr[S_UART][11:0]),
    .wdata_i (wdata[S_UART]), .wstrb_i (wstrb[S_UART]),
    .ack_o (ack[S_UART]), .rdata_o (rdata[S_UART]), .err_o (err[S_UART])
  );

  aon_mtimer u_mtimer (
    .clk_i, .rst_ni, .mtip_o, .msip_o, .mtime_o,
    .req_i (req[S_MTIMER]), .we_i (we[S_MTIMER]), .addr_i (addr[S_MTIMER][11:0]),
    .wdata_i (wdata[S_MTIMER]), .wstrb_i (wstrb[S_MTIMER]),
    .ack_o (ack[S_MTIMER]), .rdata_o (rdata[S_MTIMER]), .err_o (err[S_MTIMER])
  );

  aon_wake_timer u_wtimer (
    .clk_i, .rst_ni, .irq_o (wtimer_irq),
    .req_i (req[S_WTIMER]), .we_i (we[S_WTIMER]), .addr_i (addr[S_WTIMER][11:0]),
    .wdata_i (wdata[S_WTIMER]), .wstrb_i (wstrb[S_WTIMER]),
    .ack_o (ack[S_WTIMER]), .rdata_o (rdata[S_WTIMER]), .err_o (err[S_WTIMER])
  );

  tech_sync #(.WIDTH(1), .STAGES(2)) u_ext_wake_sync (
    .clk_i, .rst_ni, .d_i (ext_wake_i), .q_o (ext_wake_s)
  );

  assign irq_src = {2'b0, dbg_wdt_irq, dbg_err_irq, ext_wake_s, pmu_irq, wtimer_irq, uart_irq};

  aon_intc #(.N(8)) u_intc (
    .clk_i, .rst_ni, .src_i (irq_src), .irq_o (meip_o),
    .req_i (req[S_INTC]), .we_i (we[S_INTC]), .addr_i (addr[S_INTC][11:0]),
    .wdata_i (wdata[S_INTC]), .wstrb_i (wstrb[S_INTC]),
    .ack_o (ack[S_INTC]), .rdata_o (rdata[S_INTC]), .err_o (err[S_INTC])
  );

  pmu #(
    .NUM_OP (3), .RESET_OP (RESET_OP), .VSETTLE_CYCLES (VSETTLE_CYCLES),
    .RET_CYCLES (RET_CYCLES), .ISO_CYCLES (ISO_CYCLES), .RST_CLK_CYCLES (RST_CLK_CYCLES)
  ) u_pmu (
    .clk_i, .rst_ni,
    .req_i (req[S_PMU]), .we_i (we[S_PMU]), .addr_i (addr[S_PMU][11:0]),
    .wdata_i (wdata[S_PMU]), .wstrb_i (wstrb[S_PMU]),
    .ack_o (ack[S_PMU]), .rdata_o (rdata[S_PMU]), .err_o (err[S_PMU]),
    .meip_i (meip_o), .mtip_i (mtip_o), .msip_i (msip_o),
    .core_sleep_i, .idle_ack_i, .cache_clean_i, .idle_req_o,
    .cg_en_o, .cg_ack_i, .bus_idle_i,
    .iso_en_o, .cpu_rst_no, .cpu_rst_ack_i, .pwr_sw_en_o, .pwr_good_i,
    .ram_ret_o (ram_ret),
    .wdt_rst_req_i (dbg_wdt_rst_req),
    .dvfs_sel_o, .dvfs_active_i, .vsel_o,
    .irq_o (pmu_irq), .state_o (pmu_state_o),
    .dbg_state_o (dbg_pstate), .dbg_op_o (dbg_op), .dbg_evt_valid_o (dbg_evt_valid),
    .dbg_evt_from_o (dbg_evt_from), .dbg_evt_to_o (dbg_evt_to), .dbg_evt_result_o (dbg_evt_result)
  );

  // ---------------- debug blocks (doc/DEBUG_SPEC.md) ----------------
  // AXI4-Lite straight from the interconnect (the blocks have their own
  // AXI front end); 14-bit local address, addr[13:12] selects the block.
  dbg_subsys #(.TRACE_DEPTH (TRACE_DEPTH)) u_dbg (
    .clk_aon_i (clk_i), .rst_aon_ni (rst_ni), .clk_cpu_i,
    .s_axil_awaddr (m_awaddr[13:0]), .s_axil_awprot (m_awprot), .s_axil_awvalid (m_awvalid[S_DBG]),
    .s_axil_awready (m_awready[S_DBG]),
    .s_axil_wdata (m_wdata), .s_axil_wstrb (m_wstrb), .s_axil_wvalid (m_wvalid[S_DBG]),
    .s_axil_wready (m_wready[S_DBG]),
    .s_axil_bresp (m_bresp[2*S_DBG +: 2]), .s_axil_bvalid (m_bvalid[S_DBG]), .s_axil_bready (m_bready[S_DBG]),
    .s_axil_araddr (m_araddr[13:0]), .s_axil_arprot (m_arprot), .s_axil_arvalid (m_arvalid[S_DBG]),
    .s_axil_arready (m_arready[S_DBG]),
    .s_axil_rdata (m_rdata[32*S_DBG +: 32]), .s_axil_rresp (m_rresp[2*S_DBG +: 2]),
    .s_axil_rvalid (m_rvalid[S_DBG]), .s_axil_rready (m_rready[S_DBG]),
    .ret_valid_i (dbg_ret_valid_i), .ret_pc_i (dbg_ret_pc_i), .ret_insn_i (dbg_ret_insn_i),
    .trap_valid_i (dbg_trap_valid_i), .trap_cause_i (dbg_trap_cause_i), .trap_pc_i (dbg_trap_pc_i),
    .trap_tval_i (dbg_trap_tval_i),
    .ic_hit_i (dbg_ic_hit_i), .ic_miss_i (dbg_ic_miss_i), .dc_hit_i (dbg_dc_hit_i),
    .dc_miss_i (dbg_dc_miss_i), .stall_i (dbg_stall_i),
    .pwr_state_i (dbg_pstate), .dvfs_op_i (dbg_op), .pmu_evt_valid_i (dbg_evt_valid),
    .pmu_evt_from_i (dbg_evt_from), .pmu_evt_to_i (dbg_evt_to), .pmu_evt_result_i (dbg_evt_result),
    .cpu_rst_req_o (dbg_wdt_rst_req), .wdt_irq_o (dbg_wdt_irq), .err_irq_o (dbg_err_irq)
  );

  logic unused_dbg;   // the debug blocks decode a 14-bit local address
  assign unused_dbg = ^{m_awaddr[31:14], m_araddr[31:14]};

  logic unused_addr;
  assign unused_addr = ^{addr[S_UART][16:12], addr[S_MTIMER][16:12], addr[S_WTIMER][16:12],
                         addr[S_INTC][16:12], addr[S_PMU][16:12], addr[S_ROM][16:14]};
endmodule
