// pmu_env_cfg.svh - PMU environment configuration
class pmu_env_cfg extends uvm_object;

  axi_lite_cfg  axi_cfg;
  pwr_cfg       pwr_cfg_h;

  // Register model (created by the env if left null)
  pmu_reg_block ral;

  // Address of the PMU register block on the AXI4-Lite bus
  bit [31:0]    base_addr = 32'h0;

  // DUT properties needed by the reference model
  bit [`PWR_ISO_W-1:0] iso_clamp = 16'h00F0;  // value of every isolated output when clamped
  int unsigned  n_opp           = PMU_N_OPP;  // legal DVFS operating points
  axi_lite_resp_e unmapped_resp = AXI_DECERR;
  axi_lite_resp_e off_domain_resp = AXI_SLVERR;
  axi_lite_resp_e reserved_resp = AXI_SLVERR;

  bit has_scoreboard = 1;
  bit has_coverage   = 1;

  // Checks that can be relaxed for a DUT that intentionally differs
  bit check_invariants  = 1;  // static relations between gate/iso/reset/switch
  bit check_dvfs_done   = 1;  // a DVFS change pending at IDLE entry completes in IDLE
  bit check_status_reg  = 1;  // STATUS read value vs. observed pins/model

  // Timeouts used by virtual sequences (clk_aon cycles)
  int unsigned state_timeout = 20000;

  `uvm_object_utils_begin(pmu_env_cfg)
    `uvm_field_int(base_addr, UVM_DEFAULT)
    `uvm_field_int(iso_clamp, UVM_DEFAULT)
    `uvm_field_int(n_opp, UVM_DEFAULT | UVM_DEC)
    `uvm_field_int(has_scoreboard, UVM_DEFAULT)
    `uvm_field_int(has_coverage, UVM_DEFAULT)
    `uvm_field_int(check_invariants, UVM_DEFAULT)
    `uvm_field_int(check_dvfs_done, UVM_DEFAULT)
    `uvm_field_int(check_status_reg, UVM_DEFAULT)
    `uvm_field_int(state_timeout, UVM_DEFAULT | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "pmu_env_cfg");
    super.new(name);
    axi_cfg   = axi_lite_cfg::type_id::create("axi_cfg");
    pwr_cfg_h = pwr_cfg::type_id::create("pwr_cfg");
  endfunction

endclass
