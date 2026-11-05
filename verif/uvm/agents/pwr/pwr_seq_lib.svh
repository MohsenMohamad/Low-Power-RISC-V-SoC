// pwr_seq_lib.svh - agent-level power stimulus sequences
//
// These are the primitive actions; the PMU-specific power-state transition
// and DVFS sequences are virtual sequences in the environment
// (env/pmu_vseq_lib.svh) that combine them with register programming.

class pwr_base_seq extends uvm_sequence #(pwr_item);
  `uvm_object_utils(pwr_base_seq)
  function new(string name = "pwr_base_seq"); super.new(name); endfunction

  task do_op(pwr_op_e op, bit [IRQ_W-1:0] irq = '0, int unsigned cycles = 0,
             bit [ISO_W-1:0] dom_out = '0);
    pwr_item t = pwr_item::type_id::create("t");
    start_item(t);
    if (!t.randomize() with { op == local::op; cycles == local::cycles; })
      `uvm_fatal("SEQ", "randomize failed")
    t.irq     = irq;
    t.dom_out = dom_out;
    finish_item(t);
  endtask
endclass

// CPU executes WFI once the domain is running.
class pwr_wfi_seq extends pwr_base_seq;
  `uvm_object_utils(pwr_wfi_seq)
  rand int unsigned delay;
  constraint c_d { delay <= 8; }
  function new(string name = "pwr_wfi_seq"); super.new(name); endfunction
  task body(); do_op(PWR_WFI, '0, delay); endtask
endclass

// Raise wake interrupt(s); they stay asserted until the CPU runs again.
class pwr_wake_seq extends pwr_base_seq;
  `uvm_object_utils(pwr_wake_seq)
  rand bit [IRQ_W-1:0] irq;
  rand int unsigned    delay;
  constraint c_irq { irq != 0; soft $countones(irq) <= 2; delay <= 8; }
  function new(string name = "pwr_wake_seq"); super.new(name); endfunction
  task body(); do_op(PWR_WAKE, irq, delay); endtask
endclass

// Short pulses on IRQ lines (e.g. masked sources that must NOT wake).
class pwr_irq_pulse_seq extends pwr_base_seq;
  `uvm_object_utils(pwr_irq_pulse_seq)
  rand bit [IRQ_W-1:0] irq;
  rand int unsigned    width;
  constraint c_w { width inside {[1:10]}; }
  function new(string name = "pwr_irq_pulse_seq"); super.new(name); endfunction
  task body();
    do_op(PWR_IRQ_SET, irq);
    do_op(PWR_WAIT, '0, width);
    do_op(PWR_IRQ_CLR, irq);
  endtask
endclass

// Drive a pattern on the raw domain outputs.
class pwr_dom_out_seq extends pwr_base_seq;
  `uvm_object_utils(pwr_dom_out_seq)
  rand bit [ISO_W-1:0] val;
  function new(string name = "pwr_dom_out_seq"); super.new(name); endfunction
  task body(); do_op(PWR_DOM_OUT, '0, 0, val); endtask
endclass

class pwr_wait_seq extends pwr_base_seq;
  `uvm_object_utils(pwr_wait_seq)
  rand int unsigned cycles;
  constraint c_c { cycles inside {[1:50]}; }
  function new(string name = "pwr_wait_seq"); super.new(name); endfunction
  task body(); do_op(PWR_WAIT, '0, cycles); endtask
endclass
