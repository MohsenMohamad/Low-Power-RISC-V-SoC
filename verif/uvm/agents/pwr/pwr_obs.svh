// pwr_obs.svh - snapshot of all power-interface pins at one clock edge
class pwr_obs extends uvm_sequence_item;

  realtime          t;
  longint unsigned  cycle;
  bit               rst_n;
  bit               clk_en, iso_en, ret_en, pwr_en, dom_rst_n, pwr_good, wfi;
  bit [1:0]         dvfs_sel;
  bit [IRQ_W-1:0]   wake_irq;
  bit [ISO_W-1:0]   dom_out, dom_out_iso;
  bit               has_x;   // any monitored pin was X/Z

  `uvm_object_utils(pwr_obs)

  function new(string name = "pwr_obs");
    super.new(name);
  endfunction

  // Compact vector of the PMU control outputs, for change detection
  function bit [7:0] ctrl_vec();
    return {dvfs_sel, clk_en, iso_en, ret_en, pwr_en, dom_rst_n, pwr_good};
  endfunction

  function bit same_as(pwr_obs o);
    return (o != null) && rst_n == o.rst_n && ctrl_vec() == o.ctrl_vec() && wfi == o.wfi &&
           wake_irq == o.wake_irq && dom_out == o.dom_out && dom_out_iso == o.dom_out_iso &&
           has_x == o.has_x;
  endfunction

  function string convert2string();
    return $sformatf("@%0t cyc=%0d rst_n=%0b clk_en=%0b iso=%0b ret=%0b pwr_en=%0b pgood=%0b dom_rst_n=%0b dvfs=%0d wfi=%0b irq=0x%0h out=0x%0h iso_out=0x%0h%s",
                     t, cycle, rst_n, clk_en, iso_en, ret_en, pwr_en, pwr_good, dom_rst_n, dvfs_sel,
                     wfi, wake_irq, dom_out, dom_out_iso, has_x ? " X!" : "");
  endfunction

endclass
