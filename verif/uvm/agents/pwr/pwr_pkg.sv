// -----------------------------------------------------------------------------
// pwr_pkg.sv - reusable power-domain agent (UVM, IEEE 1800.2)
//
//   pwr_cfg        switch latencies, CPU model options, domain-output noise
//   pwr_item       stimulus: WFI, wake IRQ, raw IRQ levels, domain outputs, wait
//   pwr_obs        monitor snapshot of every pin (published on any change)
//   pwr_driver     reactive power-switch + CPU model, executes pwr_items
//   pwr_monitor    passive, publishes pwr_obs on change
//   pwr_coverage   pin-level edge coverage
//   pwr_agent
//   sequences      wfi, wake, irq noise, domain-output stimulus
//
// The agent knows nothing about a particular PMU's sequencing rules; those
// live in the environment's reference model.
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"

package pwr_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int IRQ_W = `PWR_IRQ_W;
  localparam int ISO_W = `PWR_ISO_W;

  typedef enum {
    PWR_WFI,        // CPU executes WFI (waits until the domain is running)
    PWR_WAKE,       // assert wake IRQ(s), held until the CPU is running again
    PWR_IRQ_SET,    // raw IRQ level set (no auto-clear)
    PWR_IRQ_CLR,    // raw IRQ level clear
    PWR_DOM_OUT,    // drive raw domain outputs
    PWR_WAIT        // idle for N cycles
  } pwr_op_e;

  `include "pwr_cfg.svh"
  `include "pwr_item.svh"
  `include "pwr_obs.svh"
  `include "pwr_sequencer.svh"
  `include "pwr_driver.svh"
  `include "pwr_monitor.svh"
  `include "pwr_coverage.svh"
  `include "pwr_agent.svh"
  `include "pwr_seq_lib.svh"

endpackage
