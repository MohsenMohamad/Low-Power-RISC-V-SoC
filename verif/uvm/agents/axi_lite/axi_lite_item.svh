// axi_lite_item.svh - one AXI4-Lite read or write transaction
class axi_lite_item extends uvm_sequence_item;

  // ---------------- request ----------------
  rand axi_lite_kind_e kind;
  rand bit [31:0]      addr;
  rand bit [31:0]      data;     // write data, or read data after completion
  rand bit [3:0]       strb;
  rand bit [2:0]       prot;

  // ---------------- timing (in clock cycles) ----------------
  rand axi_lite_dly_e  dly_mode;
  rand int unsigned    aw_delay;     // before AWVALID
  rand int unsigned    w_delay;      // before WVALID (relative to item start)
  rand int unsigned    ar_delay;     // before ARVALID
  rand int unsigned    bready_delay; // before BREADY
  rand int unsigned    rready_delay; // before RREADY

  // ---------------- response (filled by driver / monitor) ----------------
  axi_lite_resp_e      resp;

  // Monitor timestamps (simulation time) of the handshakes.
  realtime             t_req;   // first request-channel handshake (AW, W or AR)
  realtime             t_exec;  // last request-channel handshake (AW and W done / AR)
  realtime             t_resp;  // B or R handshake
  int unsigned         req_wait;   // cycles VALID was waiting for READY (request)
  int unsigned         resp_wait;  // cycles B/RVALID waited for B/RREADY
  int unsigned         gap;        // idle cycles since previous transaction (same dir)

  constraint c_align  { addr[1:0] == 2'b00; }
  constraint c_strb   { kind == AXI_READ -> strb == 4'hF;
                        strb dist { 4'hF := 9, [4'h0:4'hE] :/ 1 }; }
  constraint c_prot   { soft prot == 3'b000; }
  constraint c_dlymode{ soft dly_mode == AXI_DLY_RANDOM; }

  constraint c_delays {
    aw_delay <= 64; w_delay <= 64; ar_delay <= 64; bready_delay <= 64; rready_delay <= 64;
    if (dly_mode == AXI_DLY_ZERO) {
      aw_delay == 0; w_delay == 0; ar_delay == 0; bready_delay == 0; rready_delay == 0;
    } else if (dly_mode == AXI_DLY_SHORT) {
      aw_delay <= 2; w_delay <= 2; ar_delay <= 2; bready_delay <= 2; rready_delay <= 2;
    } else if (dly_mode == AXI_DLY_RANDOM) {
      aw_delay     dist { 0 := 6, [1:3] := 3, [4:10] := 1 };
      w_delay      dist { 0 := 6, [1:3] := 3, [4:10] := 1 };
      ar_delay     dist { 0 := 6, [1:3] := 3, [4:10] := 1 };
      bready_delay dist { 0 := 6, [1:3] := 3, [4:10] := 1 };
      rready_delay dist { 0 := 6, [1:3] := 3, [4:10] := 1 };
    } else {
      aw_delay inside {[10:64]}; w_delay inside {[0:64]}; ar_delay inside {[10:64]};
      bready_delay inside {[5:64]}; rready_delay inside {[5:64]};
    }
  }

  `uvm_object_utils_begin(axi_lite_item)
    `uvm_field_enum(axi_lite_kind_e, kind, UVM_DEFAULT)
    `uvm_field_int(addr, UVM_DEFAULT)
    `uvm_field_int(data, UVM_DEFAULT)
    `uvm_field_int(strb, UVM_DEFAULT)
    `uvm_field_int(prot, UVM_DEFAULT)
    `uvm_field_enum(axi_lite_resp_e, resp, UVM_DEFAULT)
    `uvm_field_int(aw_delay, UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(w_delay, UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(ar_delay, UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(bready_delay, UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(rready_delay, UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "axi_lite_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%s addr=0x%08h data=0x%08h strb=%b resp=%s t=[%0t..%0t]",
                     kind == AXI_WRITE ? "WR" : "RD", addr, data, strb, resp.name(), t_req, t_resp);
  endfunction

endclass
