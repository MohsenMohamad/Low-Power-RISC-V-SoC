// -----------------------------------------------------------------------------
// pmu_dut_wrap.sv - connects the DUT to the verification interfaces
//
// This is the only file that knows the DUT's port names. To verify the real
// PMU, compile a different file defining `pmu_dut_wrap` with the same two
// interface ports (select it with DUT_WRAP=... in scripts/Makefile) and set
// ISO_CLAMP / register-model differences in the test configuration.
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"
`ifndef PMU_STUB_BUG_MODE
  `define PMU_STUB_BUG_MODE 0
`endif

module pmu_dut_wrap #(
  parameter logic [`PWR_ISO_W-1:0] ISO_CLAMP = 16'h00F0
) (
  input logic   clk_aon,
  input logic   rst_aon_n,
  axi_lite_if   axi,
  pwr_if        pwr
);

  pmu_stub #(
    .IRQ_W     (`PWR_IRQ_W),
    .ISO_W     (`PWR_ISO_W),
    .ISO_CLAMP (ISO_CLAMP),
    .BUG_MODE  (`PMU_STUB_BUG_MODE)
  ) u_pmu (
    .clk_aon          (clk_aon),
    .rst_aon_n        (rst_aon_n),
    .s_axi_awaddr     (axi.awaddr),
    .s_axi_awprot     (axi.awprot),
    .s_axi_awvalid    (axi.awvalid),
    .s_axi_awready    (axi.awready),
    .s_axi_wdata      (axi.wdata),
    .s_axi_wstrb      (axi.wstrb),
    .s_axi_wvalid     (axi.wvalid),
    .s_axi_wready     (axi.wready),
    .s_axi_bresp      (axi.bresp),
    .s_axi_bvalid     (axi.bvalid),
    .s_axi_bready     (axi.bready),
    .s_axi_araddr     (axi.araddr),
    .s_axi_arprot     (axi.arprot),
    .s_axi_arvalid    (axi.arvalid),
    .s_axi_arready    (axi.arready),
    .s_axi_rdata      (axi.rdata),
    .s_axi_rresp      (axi.rresp),
    .s_axi_rvalid     (axi.rvalid),
    .s_axi_rready     (axi.rready),
    .cpu_clk_en_o     (pwr.clk_en),
    .cpu_iso_en_o     (pwr.iso_en),
    .cpu_ret_en_o     (pwr.ret_en),
    .cpu_pwr_en_o     (pwr.pwr_en),
    .cpu_pwr_good_i   (pwr.pwr_good),
    .cpu_rst_n_o      (pwr.dom_rst_n),
    .dvfs_sel_o       (pwr.dvfs_sel),
    .cpu_wfi_i        (pwr.wfi),
    .wake_irq_i       (pwr.wake_irq),
    .pd_cpu_out_i     (pwr.dom_out),
    .pd_cpu_out_iso_o (pwr.dom_out_iso)
  );

endmodule
