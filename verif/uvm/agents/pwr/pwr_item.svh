// pwr_item.svh - power agent stimulus item
class pwr_item extends uvm_sequence_item;

  rand pwr_op_e          op;
  rand bit [IRQ_W-1:0]   irq;      // PWR_WAKE / PWR_IRQ_SET / PWR_IRQ_CLR
  rand bit [ISO_W-1:0]   dom_out;  // PWR_DOM_OUT
  rand int unsigned      cycles;   // PWR_WAIT, or delay before the action
  bit                    timed_out;

  constraint c_cycles { cycles <= 200; soft cycles <= 20; }
  constraint c_wake   { op == PWR_WAKE -> irq != 0; }

  `uvm_object_utils_begin(pwr_item)
    `uvm_field_enum(pwr_op_e, op, UVM_DEFAULT)
    `uvm_field_int(irq, UVM_DEFAULT)
    `uvm_field_int(dom_out, UVM_DEFAULT)
    `uvm_field_int(cycles, UVM_DEFAULT | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "pwr_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%s irq=0x%0h dom_out=0x%0h cycles=%0d", op.name(), irq, dom_out, cycles);
  endfunction

endclass
