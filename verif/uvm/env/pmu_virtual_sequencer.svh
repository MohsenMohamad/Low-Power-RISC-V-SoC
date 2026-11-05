// pmu_virtual_sequencer.svh
class pmu_virtual_sequencer extends uvm_sequencer;
  `uvm_component_utils(pmu_virtual_sequencer)

  axi_lite_sequencer axi_sqr;
  pwr_sequencer      pwr_sqr;
  pmu_reg_block      ral;
  pmu_env_cfg        cfg;
  pmu_state_tracker  tracker;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
