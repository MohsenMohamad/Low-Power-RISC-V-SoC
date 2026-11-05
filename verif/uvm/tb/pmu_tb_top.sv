// -----------------------------------------------------------------------------
// pmu_tb_top.sv - UVM testbench top for the PMU subsystem
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"
`timescale 1ns/1ps

module pmu_tb_top;

  import uvm_pkg::*;
  import pmu_test_pkg::*;

  localparam logic [`PWR_ISO_W-1:0] ISO_CLAMP = 16'h00F0;

  logic clk_aon   = 1'b0;
  logic rst_aon_n = 1'b0;

  always #5 clk_aon = ~clk_aon;          // 100 MHz always-on clock

  initial begin
    rst_aon_n = 1'b0;
    repeat (5) @(posedge clk_aon);
    #1 rst_aon_n = 1'b1;
  end

  axi_lite_if axi_if (.aclk(clk_aon), .aresetn(rst_aon_n));
  pwr_if      pwr_vif (.clk(clk_aon), .rst_n(rst_aon_n));

  pmu_dut_wrap #(.ISO_CLAMP(ISO_CLAMP)) dut (
    .clk_aon   (clk_aon),
    .rst_aon_n (rst_aon_n),
    .axi       (axi_if),
    .pwr       (pwr_vif)
  );

  // AXI4-Lite protocol assertions are bound into axi_lite_if (tb/axi_lite_bind.sv)

  initial begin
    uvm_config_db#(virtual axi_lite_if)::set(null, "uvm_test_top", "axi_vif", axi_if);
    uvm_config_db#(virtual pwr_if)::set(null, "uvm_test_top", "pwr_vif", pwr_vif);
    uvm_config_db#(bit [`PWR_ISO_W-1:0])::set(null, "uvm_test_top", "iso_clamp", ISO_CLAMP);
    run_test();
  end

`ifdef PMU_DUMP
  initial begin
    $dumpfile("pmu_tb.vcd");
    $dumpvars(0, pmu_tb_top);
  end
`endif

endmodule
