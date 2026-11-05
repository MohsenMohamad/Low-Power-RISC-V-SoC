// -----------------------------------------------------------------------------
// pwr_if.sv - power control/status interface between a PMU and one switchable
// power domain (here PD_CPU).
//
// Monitored (PMU outputs): clock gate enable, isolation enable, retention
// enable, power switch enable, domain reset, DVFS clock-mux select, and the
// isolated domain outputs as seen by the always-on side.
// Driven by the agent (models the power switch, the CPU and wake sources):
// power_good, WFI, wake interrupts and the raw (pre-isolation) domain outputs.
//
// Widths are fixed by macros so the virtual interface type stays simple;
// override with +define+PWR_IRQ_W=<n> / +define+PWR_ISO_W=<n> if needed.
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"

interface pwr_if (input logic clk, input logic rst_n);

  // PMU -> domain controls
  logic                  clk_en;      // 1 = domain clock running
  logic                  iso_en;      // 1 = isolation clamps on
  logic                  ret_en;      // 1 = retention mode
  logic                  pwr_en;      // 1 = power switch on
  logic                  dom_rst_n;   // domain reset, active low
  logic [1:0]            dvfs_sel;    // clock-mux select (operating point)

  // switch / domain / wake sources -> PMU
  logic                  pwr_good;
  logic                  wfi;
  logic [`PWR_IRQ_W-1:0] wake_irq;
  logic [`PWR_ISO_W-1:0] dom_out;     // raw domain outputs
  logic [`PWR_ISO_W-1:0] dom_out_iso; // after isolation cells (AON side)

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output pwr_good, wfi, wake_irq, dom_out;
    input  clk_en, iso_en, ret_en, pwr_en, dom_rst_n, dvfs_sel, dom_out_iso;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input clk_en, iso_en, ret_en, pwr_en, dom_rst_n, dvfs_sel,
          pwr_good, wfi, wake_irq, dom_out, dom_out_iso;
  endclocking

  task automatic drive_reset();
    pwr_good <= 1'b0;
    wfi      <= 1'b0;
    wake_irq <= '0;
    dom_out  <= '0;
  endtask

endinterface
