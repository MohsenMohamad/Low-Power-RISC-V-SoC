// axi_lite_reg_adapter.svh - uvm_reg frontdoor through the AXI4-Lite agent
//
// The driver writes the response back into the request item, so
// provides_responses = 0 and bus2reg() reads the completed item.
// Any non-OKAY response maps to UVM_NOT_OK (the predictor then leaves the
// mirror unchanged, matching a slave that ignores an erroring access).
class axi_lite_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(axi_lite_reg_adapter)

  // Delay profile applied to register accesses (random by default so RAL
  // traffic also exercises back-pressure).
  axi_lite_dly_e dly_mode = AXI_DLY_RANDOM;

  function new(string name = "axi_lite_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axi_lite_item t = axi_lite_item::type_id::create("reg_tr");
    if (!t.randomize() with { kind == ((rw.kind == UVM_WRITE) ? AXI_WRITE : AXI_READ);
                              addr == rw.addr[31:0];
                              dly_mode == local::dly_mode; })
      `uvm_fatal("ADAPT", "randomize failed")
    t.data = rw.data[31:0];
    t.strb = (rw.kind == UVM_WRITE) ? rw.byte_en[3:0] : 4'hF;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axi_lite_item t;
    if (!$cast(t, bus_item)) begin
      `uvm_fatal("ADAPT", "bus2reg: not an axi_lite_item")
      return;
    end
    rw.kind    = (t.kind == AXI_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr    = t.addr;
    rw.data    = t.data;
    rw.byte_en = t.strb;
    rw.n_bits  = 32;
    rw.status  = (t.resp == AXI_OKAY) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction

endclass
