// -----------------------------------------------------------------------------
// axi_lite_pkg.sv - reusable AXI4-Lite master agent (UVM, IEEE 1800.2)
//
//   axi_lite_cfg           agent configuration (vif, active/passive, coverage)
//   axi_lite_item          one read or write, with per-channel delays
//   axi_lite_driver        master driver (AW/W independent, B/R back-pressure)
//   axi_lite_monitor       passive monitor, timestamps every handshake
//   axi_lite_coverage      protocol-level functional coverage
//   axi_lite_agent         container
//   axi_lite_reg_adapter   uvm_reg <-> axi_lite_item adapter
//   sequences              single / back-to-back / random-delay / error
// -----------------------------------------------------------------------------
package axi_lite_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum bit { AXI_READ = 1'b0, AXI_WRITE = 1'b1 } axi_lite_kind_e;

  typedef enum bit [1:0] {
    AXI_OKAY   = 2'b00,
    AXI_EXOKAY = 2'b01,   // illegal in AXI4-Lite, listed for completeness
    AXI_SLVERR = 2'b10,
    AXI_DECERR = 2'b11
  } axi_lite_resp_e;

  // Delay profile used by sequences to bias the per-channel delays
  typedef enum { AXI_DLY_ZERO, AXI_DLY_SHORT, AXI_DLY_RANDOM, AXI_DLY_LONG } axi_lite_dly_e;

  `include "axi_lite_cfg.svh"
  `include "axi_lite_item.svh"
  `include "axi_lite_sequencer.svh"
  `include "axi_lite_driver.svh"
  `include "axi_lite_monitor.svh"
  `include "axi_lite_coverage.svh"
  `include "axi_lite_agent.svh"
  `include "axi_lite_reg_adapter.svh"
  `include "axi_lite_seq_lib.svh"

endpackage
