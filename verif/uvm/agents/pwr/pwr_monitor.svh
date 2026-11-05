// pwr_monitor.svh - passive power-interface monitor
//
// Samples every pin through mon_cb on each clock and publishes a pwr_obs
// snapshot whenever anything changed (including reset). Snapshots carry the
// sample time so the scoreboard can correlate them with bus transactions.
class pwr_monitor extends uvm_monitor;
  `uvm_component_utils(pwr_monitor)

  pwr_cfg        cfg;
  virtual pwr_if vif;

  uvm_analysis_port #(pwr_obs) ap;

  pwr_obs          last;
  longint unsigned cycle;
  int unsigned     n_pub;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) `uvm_fatal("CFG", "pwr_monitor: cfg not set")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      pwr_obs o;
      @(vif.mon_cb);
      cycle++;
      o = pwr_obs::type_id::create("obs");
      o.t           = $realtime;
      o.cycle       = cycle;
      o.rst_n       = (vif.rst_n === 1'b1);
      o.clk_en      = vif.mon_cb.clk_en;
      o.iso_en      = vif.mon_cb.iso_en;
      o.ret_en      = vif.mon_cb.ret_en;
      o.pwr_en      = vif.mon_cb.pwr_en;
      o.dom_rst_n   = vif.mon_cb.dom_rst_n;
      o.pwr_good    = vif.mon_cb.pwr_good;
      o.wfi         = vif.mon_cb.wfi;
      o.dvfs_sel    = vif.mon_cb.dvfs_sel;
      o.wake_irq    = vif.mon_cb.wake_irq;
      o.dom_out     = vif.mon_cb.dom_out;
      o.dom_out_iso = vif.mon_cb.dom_out_iso;
      o.has_x       = o.rst_n && $isunknown({vif.mon_cb.clk_en, vif.mon_cb.iso_en, vif.mon_cb.ret_en,
                                              vif.mon_cb.pwr_en, vif.mon_cb.dom_rst_n, vif.mon_cb.dvfs_sel,
                                              vif.mon_cb.dom_out_iso});
      if (!o.same_as(last)) begin
        `uvm_info("PWRMON", o.convert2string(), UVM_HIGH)
        ap.write(o);
        n_pub++;
        last = o;
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("PWRMON", $sformatf("published %0d snapshots over %0d cycles", n_pub, cycle), UVM_LOW)
  endfunction

endclass
