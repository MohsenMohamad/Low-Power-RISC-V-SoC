// pwr_cfg.svh - power agent configuration
class pwr_cfg extends uvm_object;

  virtual pwr_if vif;

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit has_coverage = 1;

  // Power-switch model: power_good rises pgood_on_{min,max} cycles after the
  // switch is enabled and falls pgood_off_{min,max} cycles after it is
  // disabled (randomised per event).
  int unsigned pgood_on_min  = 2;
  int unsigned pgood_on_max  = 12;
  int unsigned pgood_off_min = 0;
  int unsigned pgood_off_max = 3;

  // CPU model: cycles after the domain clock restarts before WFI drops.
  int unsigned wfi_exit_delay = 0;

  // Wake IRQs raised by PWR_WAKE are cleared this many cycles after the
  // domain is running again (models the CPU servicing the interrupt).
  int unsigned irq_clear_min = 1;
  int unsigned irq_clear_max = 6;

  // Drive random values on the raw domain outputs while the domain is not
  // running (models undefined outputs of an off/reset domain), and toggle
  // them randomly while it runs.
  bit rand_dom_out = 1;

  `uvm_object_utils_begin(pwr_cfg)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_DEFAULT)
    `uvm_field_int(has_coverage, UVM_DEFAULT)
    `uvm_field_int(pgood_on_min, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(pgood_on_max, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(pgood_off_min, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(pgood_off_max, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(wfi_exit_delay, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(rand_dom_out, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "pwr_cfg");
    super.new(name);
  endfunction

endclass
