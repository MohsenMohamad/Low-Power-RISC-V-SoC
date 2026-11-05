// -----------------------------------------------------------------------------
// soc_top - Low-power RISC-V SoC top level
//
// Power domains (see upf/soc_top.upf):
//   PD_AON  everything in this module except u_pd_cpu (always on, clk_aon)
//   PD_CPU  u_pd_cpu (switchable through u_pwr_sw, clocked by clk_cpu)
//
// Clocks:
//   clk_aon_i       always-on clock (PMU, bus, memories, peripherals)
//   clk_op_i[2:0]   DVFS operating-point clocks (OP0 slowest .. OP2 fastest),
//                   asynchronous to clk_aon_i and to each other
//   clk_cpu_root  = glitch-free mux of clk_op_i (u_dvfs_mux)
//   clk_cpu       = clk_cpu_root gated by the PMU (u_clk_rst)
//
// Clock-domain crossings (all in PD_AON):
//   CPU AXI4-Lite master   clk_cpu -> clk_aon   u_bridge (5 async FIFOs)
//   bridge slave idle      clk_cpu -> clk_aon   tech_sync in u_bridge
//   core_sleep/idle_ack/
//   cache_clean            clk_cpu -> clk_aon   u_core_sync (levels, 4-phase)
//   idle_req, meip/mtip/
//   msip                   clk_aon -> clk_cpu   tech_sync in pd_cpu (once, at the CPU boundary)
//   mtime[63:0]            clk_aon -> clk_cpu   cdc_snapshot_src (here) / _dst (pd_cpu)
//   clock-gate enable/ack  clk_aon <-> root     u_clk_rst
//   CPU reset release/ack  clk_aon <-> root     u_clk_rst
//   DVFS select / status   clk_aon <-> clk_op   u_dvfs_mux / u_dvfs_sync
//   ext_wake_i, uart_rx_i  async -> clk_aon     tech_sync in u_aon
// -----------------------------------------------------------------------------
module soc_top #(
  parameter ROM_INIT       = "",
  parameter int    VSETTLE_CYCLES = 8,
  parameter int    RET_CYCLES     = 4,
  parameter int    ISO_CYCLES     = 2,
  parameter int    RST_CLK_CYCLES = 4,
  parameter int    PSW_ON_DLY     = 8,
  parameter int    PSW_OFF_DLY    = 4,
  parameter logic [1:0] RESET_OP  = 2'd2,
  // Address map (doc/SPEC.md). The CPU's reset vector, RAM base and cacheable
  // ranges and the AON decoder are all derived from these values.
  parameter logic [31:0] BOOT_ADDR      = 32'h0000_0000,
  parameter logic [31:0] ROM_BASE       = 32'h0000_0000,
  parameter logic [31:0] ROM_MASK       = 32'hFFFF_C000,   // 16 KB, cacheable (I-side)
  parameter logic [31:0] RAM_BASE       = 32'h1000_0000,
  parameter logic [31:0] RAM_MASK       = 32'hFFFE_0000,   // 128 KB, cacheable
  parameter logic [31:0] RAM_ALIAS_BASE = 32'h3000_0000    // 128 KB uncached alias of RAM
) (
  input  logic       clk_aon_i,
  input  logic [2:0] clk_op_i,
  input  logic       por_ni,
  input  logic       test_en_i,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  input  logic       ext_wake_i,
  output logic [1:0] vsel_o        // regulator voltage select for PD_CPU
);
  // ---------------------------------------------------------------------------
  // Always-on reset
  // ---------------------------------------------------------------------------
  logic rst_aon_n;
  logic [4:0] pmu_state;  // observed by the testbench / coverage
  rst_sync u_aon_rst (.clk_i (clk_aon_i), .arst_ni (por_ni), .rst_no (rst_aon_n));

  // ---------------------------------------------------------------------------
  // DVFS clock mux and CPU clock / reset control
  // ---------------------------------------------------------------------------
  logic       clk_cpu_root, clk_cpu;
  logic [1:0] dvfs_sel;
  logic [2:0] dvfs_active, dvfs_active_s;
  logic       cg_en, cg_ack, cpu_rst_req_n, cpu_rst_ack, cpu_rst_n, bridge_rst_n;

  dvfs_clk_mux #(.N(3), .RESET_SEL(RESET_OP)) u_dvfs_mux (
    .clk_i (clk_op_i), .rst_ni (por_ni), .sel_i (dvfs_sel), .test_en_i (test_en_i),
    .clk_o (clk_cpu_root), .active_o (dvfs_active)
  );

  tech_sync #(.WIDTH(3), .STAGES(2), .RESET_VAL(3'(1) << RESET_OP)) u_dvfs_sync (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_n), .d_i (dvfs_active), .q_o (dvfs_active_s)
  );

  cpu_clk_rst_ctrl u_clk_rst (
    .clk_cpu_root_i (clk_cpu_root), .clk_aon_i (clk_aon_i),
    .por_ni (por_ni), .rst_aon_ni (rst_aon_n), .test_en_i (test_en_i),
    .cg_en_i (cg_en), .cg_ack_o (cg_ack),
    .cpu_rst_req_ni (cpu_rst_req_n), .cpu_rst_ack_o (cpu_rst_ack),
    .clk_cpu_o (clk_cpu), .cpu_rst_no (cpu_rst_n), .bridge_rst_no (bridge_rst_n)
  );

  // ---------------------------------------------------------------------------
  // Power switch for PD_CPU
  // ---------------------------------------------------------------------------
  logic pwr_sw_en, pwr_good, pd_cpu_supply_on;

  tech_pwr_switch #(.ON_DLY (PSW_ON_DLY), .OFF_DLY (PSW_OFF_DLY)) u_pwr_sw (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_n), .sw_en_i (pwr_sw_en),
    .pwr_good_o (pwr_good), .supply_on_o (pd_cpu_supply_on)
  );

  // ---------------------------------------------------------------------------
  // PD_CPU
  // ---------------------------------------------------------------------------
  logic meip, mtip, msip, idle_req;

  // raw (un-isolated) PD_CPU outputs
  logic        c_awvalid, c_wvalid, c_bready, c_arvalid, c_rready;
  logic [31:0] c_awaddr, c_wdata, c_araddr;
  logic [2:0]  c_awprot, c_arprot;
  logic [3:0]  c_wstrb;
  logic        c_idle_ack, c_core_sleep, c_cache_clean, c_mtime_req;

  // bridge -> PD_CPU
  logic        b_awready, b_wready, b_bvalid, b_arready, b_rvalid;
  logic [1:0]  b_bresp, b_rresp;
  logic [31:0] b_rdata;

  // mtime export: coherent snapshot crossing (source half, PD_AON)
  logic [63:0] mtime, mtime_snap;
  logic        mtime_ack, i_mtime_req;
  cdc_snapshot_src #(.W(64)) u_mtime_src (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_n), .value_i (mtime),
    .req_tgl_i (i_mtime_req), .ack_tgl_o (mtime_ack), .snap_o (mtime_snap)
  );

  pd_cpu #(
    .BOOT_ADDR (BOOT_ADDR), .ROM_BASE (ROM_BASE), .ROM_MASK (ROM_MASK),
    .RAM_BASE (RAM_BASE), .RAM_MASK (RAM_MASK)
  ) u_pd_cpu (
    .clk_i (clk_cpu), .rst_ni (cpu_rst_n),
    .meip_i (meip), .mtip_i (mtip), .msip_i (msip), .idle_req_i (idle_req),
    .idle_ack_o (c_idle_ack), .core_sleep_o (c_core_sleep),
    .cache_clean_o (c_cache_clean),
    .mtime_snap_i (mtime_snap), .mtime_ack_i (mtime_ack), .mtime_req_o (c_mtime_req),
    .m_awvalid_o (c_awvalid), .m_awready_i (b_awready), .m_awaddr_o (c_awaddr), .m_awprot_o (c_awprot),
    .m_wvalid_o (c_wvalid), .m_wready_i (b_wready), .m_wdata_o (c_wdata), .m_wstrb_o (c_wstrb),
    .m_bvalid_i (b_bvalid), .m_bready_o (c_bready), .m_bresp_i (b_bresp),
    .m_arvalid_o (c_arvalid), .m_arready_i (b_arready), .m_araddr_o (c_araddr), .m_arprot_o (c_arprot),
    .m_rvalid_i (b_rvalid), .m_rready_o (c_rready), .m_rdata_i (b_rdata), .m_rresp_i (b_rresp)
  );

  // ---------------------------------------------------------------------------
  // Isolation of every PD_CPU output (clamp 0), located in PD_AON
  // ---------------------------------------------------------------------------
  logic        iso_en;
  localparam int ISO_W = 1+32+3 + 1+32+4 + 1 + 1+32+3 + 1 + 4;
  logic [ISO_W-1:0] iso_in, iso_out;

  logic        i_awvalid, i_wvalid, i_bready, i_arvalid, i_rready;
  logic [31:0] i_awaddr, i_wdata, i_araddr;
  logic [2:0]  i_awprot, i_arprot;
  logic [3:0]  i_wstrb;
  logic        i_idle_ack, i_core_sleep, i_cache_clean;

  assign iso_in = {c_awvalid, c_awaddr, c_awprot, c_wvalid, c_wdata, c_wstrb, c_bready,
                   c_arvalid, c_araddr, c_arprot, c_rready,
                   c_idle_ack, c_core_sleep, c_cache_clean, c_mtime_req};

  tech_iso #(.WIDTH(ISO_W), .CLAMP('0)) u_iso (
    .iso_en_i (iso_en), .d_i (iso_in), .q_o (iso_out)
  );

  assign {i_awvalid, i_awaddr, i_awprot, i_wvalid, i_wdata, i_wstrb, i_bready,
          i_arvalid, i_araddr, i_arprot, i_rready,
          i_idle_ack, i_core_sleep, i_cache_clean, i_mtime_req} = iso_out;

  // ---------------------------------------------------------------------------
  // CPU -> AON bus crossing
  // ---------------------------------------------------------------------------
  logic        a_awvalid, a_awready, a_wvalid, a_wready, a_bvalid, a_bready;
  logic        a_arvalid, a_arready, a_rvalid, a_rready;
  logic [31:0] a_awaddr, a_wdata, a_araddr, a_rdata;
  logic [2:0]  a_awprot, a_arprot;
  logic [3:0]  a_wstrb;
  logic [1:0]  a_bresp, a_rresp;
  logic        bus_idle;

  axil_cdc_bridge #(.DEPTH(4)) u_bridge (
    .clk_s_i (clk_cpu), .rst_s_ni (bridge_rst_n),
    .s_awvalid_i (i_awvalid), .s_awready_o (b_awready), .s_awaddr_i (i_awaddr), .s_awprot_i (i_awprot),
    .s_wvalid_i (i_wvalid), .s_wready_o (b_wready), .s_wdata_i (i_wdata), .s_wstrb_i (i_wstrb),
    .s_bvalid_o (b_bvalid), .s_bready_i (i_bready), .s_bresp_o (b_bresp),
    .s_arvalid_i (i_arvalid), .s_arready_o (b_arready), .s_araddr_i (i_araddr), .s_arprot_i (i_arprot),
    .s_rvalid_o (b_rvalid), .s_rready_i (i_rready), .s_rdata_o (b_rdata), .s_rresp_o (b_rresp),
    .clk_m_i (clk_aon_i), .rst_m_ni (rst_aon_n),
    .m_awvalid_o (a_awvalid), .m_awready_i (a_awready), .m_awaddr_o (a_awaddr), .m_awprot_o (a_awprot),
    .m_wvalid_o (a_wvalid), .m_wready_i (a_wready), .m_wdata_o (a_wdata), .m_wstrb_o (a_wstrb),
    .m_bvalid_i (a_bvalid), .m_bready_o (a_bready), .m_bresp_i (a_bresp),
    .m_arvalid_o (a_arvalid), .m_arready_i (a_arready), .m_araddr_o (a_araddr), .m_arprot_o (a_arprot),
    .m_rvalid_i (a_rvalid), .m_rready_o (a_rready), .m_rdata_i (a_rdata), .m_rresp_i (a_rresp),
    .idle_m_o (bus_idle)
  );

  // ---------------------------------------------------------------------------
  // PD_CPU status -> clk_aon
  // ---------------------------------------------------------------------------
  logic s_idle_ack, s_core_sleep, s_cache_clean;
  tech_sync #(.WIDTH(3), .STAGES(2)) u_core_sync (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_n),
    .d_i ({i_idle_ack, i_core_sleep, i_cache_clean}),
    .q_o ({s_idle_ack, s_core_sleep, s_cache_clean})
  );

  // ---------------------------------------------------------------------------
  // Always-on subsystem (bus, memories, peripherals, PMU)
  // ---------------------------------------------------------------------------
  aon_subsys #(
    .ROM_INIT (ROM_INIT), .VSETTLE_CYCLES (VSETTLE_CYCLES), .RET_CYCLES (RET_CYCLES),
    .ISO_CYCLES (ISO_CYCLES), .RST_CLK_CYCLES (RST_CLK_CYCLES), .RESET_OP (RESET_OP),
    .ROM_BASE (ROM_BASE), .ROM_MASK (ROM_MASK), .RAM_BASE (RAM_BASE), .RAM_MASK (RAM_MASK),
    .RAM_ALIAS_BASE (RAM_ALIAS_BASE)
  ) u_aon (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_n),
    .s_awvalid_i (a_awvalid), .s_awready_o (a_awready), .s_awaddr_i (a_awaddr), .s_awprot_i (a_awprot),
    .s_wvalid_i (a_wvalid), .s_wready_o (a_wready), .s_wdata_i (a_wdata), .s_wstrb_i (a_wstrb),
    .s_bvalid_o (a_bvalid), .s_bready_i (a_bready), .s_bresp_o (a_bresp),
    .s_arvalid_i (a_arvalid), .s_arready_o (a_arready), .s_araddr_i (a_araddr), .s_arprot_i (a_arprot),
    .s_rvalid_o (a_rvalid), .s_rready_i (a_rready), .s_rdata_o (a_rdata), .s_rresp_o (a_rresp),
    .uart_rx_i (uart_rx_i), .uart_tx_o (uart_tx_o), .ext_wake_i (ext_wake_i),
    .meip_o (meip), .mtip_o (mtip), .msip_o (msip), .mtime_o (mtime),
    .core_sleep_i (s_core_sleep), .idle_ack_i (s_idle_ack), .cache_clean_i (s_cache_clean),
    .idle_req_o (idle_req),
    .cg_en_o (cg_en), .cg_ack_i (cg_ack), .bus_idle_i (bus_idle),
    .iso_en_o (iso_en), .cpu_rst_no (cpu_rst_req_n), .cpu_rst_ack_i (cpu_rst_ack),
    .pwr_sw_en_o (pwr_sw_en), .pwr_good_i (pwr_good),
    .dvfs_sel_o (dvfs_sel), .dvfs_active_i (dvfs_active_s), .vsel_o (vsel_o),
    .pmu_state_o (pmu_state)
  );

  logic unused;
  assign unused = ^{pd_cpu_supply_on, pmu_state};
endmodule
