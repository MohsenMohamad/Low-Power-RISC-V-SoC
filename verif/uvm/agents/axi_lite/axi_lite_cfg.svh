// axi_lite_cfg.svh - AXI4-Lite agent configuration
class axi_lite_cfg extends uvm_object;

  virtual axi_lite_if vif;

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit has_coverage                  = 1;

  // Drive random values on payload signals while VALID is low, to catch a
  // slave that samples payload without a handshake.
  bit rand_idle_payload             = 1;

  // Driver gives up (uvm_error) if a handshake takes longer than this.
  int unsigned handshake_timeout    = 1000;

  // Default delay profile for items that do not constrain their delays.
  axi_lite_dly_e default_dly        = AXI_DLY_RANDOM;

  `uvm_object_utils_begin(axi_lite_cfg)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_DEFAULT)
    `uvm_field_int(has_coverage, UVM_DEFAULT)
    `uvm_field_int(rand_idle_payload, UVM_DEFAULT)
    `uvm_field_int(handshake_timeout, UVM_DEFAULT | UVM_DEC)
    `uvm_field_enum(axi_lite_dly_e, default_dly, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "axi_lite_cfg");
    super.new(name);
  endfunction

endclass
