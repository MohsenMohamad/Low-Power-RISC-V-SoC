// pmu_env.svh - PMU subsystem environment
class pmu_env extends uvm_env;
  `uvm_component_utils(pmu_env)

  pmu_env_cfg               cfg;
  axi_lite_agent            axi;
  pwr_agent                 pwr;
  pmu_reg_block             ral;
  uvm_reg_predictor #(axi_lite_item) predictor;
  axi_lite_reg_adapter      adapter;
  pmu_scoreboard            sb;
  pmu_coverage              cov;
  pmu_virtual_sequencer     vsqr;
  pmu_state_tracker         tracker;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(pmu_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CFG", "pmu_env: no pmu_env_cfg")

    // Register model
    if (cfg.ral == null) begin
      if (cfg.has_coverage) uvm_reg::include_coverage("*", UVM_CVR_FIELD_VALS);
      cfg.ral = pmu_reg_block::type_id::create("ral");
      cfg.ral.configure(null, "");
      cfg.ral.build(cfg.base_addr);
      if (cfg.has_coverage) void'(cfg.ral.set_coverage(UVM_CVR_FIELD_VALS));
    end
    ral = cfg.ral;

    axi = axi_lite_agent::type_id::create("axi", this);
    axi.cfg = cfg.axi_cfg;
    pwr = pwr_agent::type_id::create("pwr", this);
    pwr.cfg = cfg.pwr_cfg_h;

    adapter   = axi_lite_reg_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(axi_lite_item)::type_id::create("predictor", this);

    tracker = pmu_state_tracker::type_id::create("tracker");

    if (cfg.has_scoreboard) begin
      sb = pmu_scoreboard::type_id::create("sb", this);
      sb.cfg = cfg;
      sb.ral = ral;
      sb.tracker = tracker;
    end
    if (cfg.has_coverage) cov = pmu_coverage::type_id::create("cov", this);

    vsqr = pmu_virtual_sequencer::type_id::create("vsqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    tracker.vif = cfg.pwr_cfg_h.vif;

    // RAL frontdoor through the AXI4-Lite agent, explicit prediction from the monitor
    if (cfg.axi_cfg.is_active == UVM_ACTIVE) ral.default_map.set_sequencer(axi.sqr, adapter);
    ral.default_map.set_auto_predict(0);
    ral.default_map.set_check_on_read(1);
    // PD_CPU register data is checked by the scoreboard (it models power loss)
    ral.CPU_WIN.default_map.set_check_on_read(0);
    predictor.map     = ral.default_map;
    predictor.adapter = adapter;
    axi.ap.connect(predictor.bus_in);

    if (cfg.has_scoreboard) begin
      axi.ap.connect(sb.axi_imp);
      pwr.ap.connect(sb.pwr_imp);
      if (cfg.has_coverage) begin
        sb.trans_ap.connect(cov.trans_imp);
        sb.bus_ap.connect(cov.bus_imp);
      end
    end

    vsqr.axi_sqr = axi.sqr;
    vsqr.pwr_sqr = pwr.sqr;
    vsqr.ral     = ral;
    vsqr.cfg     = cfg;
    vsqr.tracker = tracker;
  endfunction

endclass
