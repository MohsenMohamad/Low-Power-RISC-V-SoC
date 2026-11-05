// -----------------------------------------------------------------------------
// pmu_env_pkg.sv - PMU subsystem verification environment
//
// Combines the AXI4-Lite agent, the power agent and the PMU register model
// with a reference model / scoreboard, functional coverage and a virtual
// sequence library for every power-state transition and DVFS change.
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"
package pmu_env_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;
  import pwr_pkg::*;
  import pmu_ral_pkg::*;

  `include "pmu_env_types.svh"
  `include "pmu_env_cfg.svh"
  `include "pmu_state_tracker.svh"
  `include "pmu_scoreboard.svh"
  `include "pmu_coverage.svh"
  `include "pmu_virtual_sequencer.svh"
  `include "pmu_env.svh"
  `include "pmu_vseq_lib.svh"

endpackage
