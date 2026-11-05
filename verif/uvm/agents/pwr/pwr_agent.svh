// pwr_agent.svh - power-domain agent
class pwr_agent extends uvm_agent;
  `uvm_component_utils(pwr_agent)

  pwr_cfg       cfg;
  pwr_sequencer sqr;
  pwr_driver    drv;
  pwr_monitor   mon;
  pwr_coverage  cov;

  uvm_analysis_port #(pwr_obs) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null && !uvm_config_db#(pwr_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CFG", "pwr_agent: no pwr_cfg")
    if (cfg.vif == null && !uvm_config_db#(virtual pwr_if)::get(this, "", "vif", cfg.vif))
      `uvm_fatal("CFG", "pwr_agent: no virtual pwr_if")
    mon = pwr_monitor::type_id::create("mon", this);
    mon.cfg = cfg;
    if (cfg.is_active == UVM_ACTIVE) begin
      sqr = pwr_sequencer::type_id::create("sqr", this);
      drv = pwr_driver::type_id::create("drv", this);
      sqr.cfg = cfg;
      drv.cfg = cfg;
    end
    if (cfg.has_coverage) cov = pwr_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ap = mon.ap;
    if (cfg.is_active == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    if (cfg.has_coverage) mon.ap.connect(cov.analysis_export);
  endfunction

endclass
