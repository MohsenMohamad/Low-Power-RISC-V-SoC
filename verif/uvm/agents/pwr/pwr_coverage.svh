// pwr_coverage.svh - pin-level coverage of the power interface (DUT independent)
class pwr_coverage extends uvm_subscriber #(pwr_obs);
  `uvm_component_utils(pwr_coverage)

  pwr_obs cur, prev;

  covergroup cg_pins;
    option.per_instance = 1;
    cp_clk_en:   coverpoint {prev.clk_en,    cur.clk_en}    { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_iso_en:   coverpoint {prev.iso_en,    cur.iso_en}    { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_ret_en:   coverpoint {prev.ret_en,    cur.ret_en}    { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_pwr_en:   coverpoint {prev.pwr_en,    cur.pwr_en}    { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_pwr_good: coverpoint {prev.pwr_good,  cur.pwr_good}  { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_rst_n:    coverpoint {prev.dom_rst_n, cur.dom_rst_n} { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_wfi:      coverpoint {prev.wfi,       cur.wfi}       { bins rise = {2'b01}; bins fall = {2'b10}; }
    cp_dvfs:     coverpoint cur.dvfs_sel { bins opp[] = {[0:2]}; }
    cp_wake:     coverpoint (cur.wake_irq != 0);
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_pins = new();
  endfunction

  function void write(pwr_obs t);
    cur = t;
    if (prev != null && t.rst_n && prev.rst_n) cg_pins.sample();
    prev = t;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("power pin coverage: %0.2f%%", cg_pins.get_inst_coverage()), UVM_LOW)
  endfunction

endclass
