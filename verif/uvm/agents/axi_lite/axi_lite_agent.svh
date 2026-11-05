// axi_lite_agent.svh - AXI4-Lite master agent
class axi_lite_agent extends uvm_agent;
  `uvm_component_utils(axi_lite_agent)

  axi_lite_cfg        cfg;
  axi_lite_sequencer  sqr;
  axi_lite_driver     drv;
  axi_lite_monitor    mon;
  axi_lite_coverage   cov;

  uvm_analysis_port #(axi_lite_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null && !uvm_config_db#(axi_lite_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CFG", "axi_lite_agent: no axi_lite_cfg")
    if (cfg.vif == null && !uvm_config_db#(virtual axi_lite_if)::get(this, "", "vif", cfg.vif))
      `uvm_fatal("CFG", "axi_lite_agent: no virtual axi_lite_if")
    mon = axi_lite_monitor::type_id::create("mon", this);
    mon.cfg = cfg;
    if (cfg.is_active == UVM_ACTIVE) begin
      sqr = axi_lite_sequencer::type_id::create("sqr", this);
      drv = axi_lite_driver::type_id::create("drv", this);
      sqr.cfg = cfg;
      drv.cfg = cfg;
    end
    if (cfg.has_coverage) cov = axi_lite_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ap = mon.ap;
    if (cfg.is_active == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    if (cfg.has_coverage) mon.ap.connect(cov.analysis_export);
  endfunction

endclass
