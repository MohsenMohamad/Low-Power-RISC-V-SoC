// axi_lite_coverage.svh - protocol-level functional coverage (DUT independent)
class axi_lite_coverage extends uvm_subscriber #(axi_lite_item);
  `uvm_component_utils(axi_lite_coverage)

  axi_lite_item tr;

  covergroup cg_xfer;
    option.per_instance = 1;
    cp_kind: coverpoint tr.kind;
    cp_resp: coverpoint tr.resp {
      bins okay   = {AXI_OKAY};
      bins slverr = {AXI_SLVERR};
      bins decerr = {AXI_DECERR};
      illegal_bins exokay = {AXI_EXOKAY};
    }
    cp_strb: coverpoint tr.strb iff (tr.kind == AXI_WRITE) {
      bins full    = {4'hF};
      bins none    = {4'h0};
      bins single[] = {4'h1, 4'h2, 4'h4, 4'h8};
      bins half[]   = {4'h3, 4'hC};
      bins other   = default;
    }
    cp_req_wait: coverpoint tr.req_wait {
      bins zero = {0};
      bins short_wait = {[1:3]};
      bins long_wait  = {[4:$]};
    }
    cp_resp_wait: coverpoint tr.resp_wait {
      bins zero = {0};
      bins short_wait = {[1:3]};
      bins long_wait  = {[4:$]};
    }
    cp_gap: coverpoint tr.gap {
      bins back_to_back = {0};
      bins short_gap    = {[1:4]};
      bins long_gap     = {[5:$]};
    }
    cp_aw_w_order: coverpoint ((tr.t_req == tr.t_exec) ? 0 : 1) iff (tr.kind == AXI_WRITE) {
      bins same_cycle = {0};
      bins split      = {1};
    }
    x_kind_resp:  cross cp_kind, cp_resp;
    x_kind_gap:   cross cp_kind, cp_gap;
    x_kind_rwait: cross cp_kind, cp_resp_wait;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_xfer = new();
  endfunction

  function void write(axi_lite_item t);
    tr = t;
    cg_xfer.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("AXI4-Lite transfer coverage: %0.2f%%", cg_xfer.get_inst_coverage()), UVM_LOW)
  endfunction

endclass
