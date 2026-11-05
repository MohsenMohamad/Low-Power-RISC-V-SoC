// -----------------------------------------------------------------------------
// pmu_sva_bind.sv - hook for the PMU power-sequencing assertions
//
// The power-sequencing SVA and formal properties are owned by the PMU
// block-level verification branch and are deliberately NOT written here.
// Once that branch is merged, add its SVA file(s) to the compile with
//   make ... EXTRA_F=<path to their filelist> DEFINES=+define+PMU_POWER_SVA
// and adjust the bind target/instance below to the module and port names
// those files use. Nothing is bound unless PMU_POWER_SVA is defined.
// -----------------------------------------------------------------------------
`ifdef PMU_POWER_SVA
  `ifndef PMU_POWER_SVA_MODULE
    `define PMU_POWER_SVA_MODULE pmu_power_sva
  `endif
  `ifndef PMU_POWER_SVA_TARGET
    `define PMU_POWER_SVA_TARGET pmu
  `endif
  // Implicit .* connection: the SVA module's ports must match the PMU's
  // port names (the usual convention for bindable checkers).
  bind `PMU_POWER_SVA_TARGET `PMU_POWER_SVA_MODULE u_pmu_power_sva (.*);
`endif
