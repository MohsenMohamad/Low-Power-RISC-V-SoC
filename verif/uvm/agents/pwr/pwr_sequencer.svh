// pwr_sequencer.svh
class pwr_sequencer extends uvm_sequencer #(pwr_item);
  `uvm_component_utils(pwr_sequencer)

  pwr_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
