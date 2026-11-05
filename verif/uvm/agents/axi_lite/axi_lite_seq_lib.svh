// axi_lite_seq_lib.svh - AXI4-Lite sequence library
//
//   axi_lite_base_seq        write()/read() helpers
//   axi_lite_single_write_seq / axi_lite_single_read_seq
//   axi_lite_b2b_seq         back-to-back writes, reads or alternating, no idle
//   axi_lite_rand_seq        random kind/address/data/strobe with random delays
//   axi_lite_err_seq         accesses expected to return SLVERR/DECERR
//
// Address selection is DUT independent: sequences take explicit address
// lists/ranges from the caller.

class axi_lite_base_seq extends uvm_sequence #(axi_lite_item);
  `uvm_object_utils(axi_lite_base_seq)

  axi_lite_dly_e dly_mode = AXI_DLY_RANDOM;

  function new(string name = "axi_lite_base_seq");
    super.new(name);
  endfunction

  task write(input bit [31:0] addr, input bit [31:0] data,
             output axi_lite_resp_e resp, input bit [3:0] strb = 4'hF);
    axi_lite_item t = axi_lite_item::type_id::create("wr");
    start_item(t);
    if (!t.randomize() with { kind == AXI_WRITE; addr == local::addr; data == local::data;
                              strb == local::strb; dly_mode == local::dly_mode; })
      `uvm_fatal("SEQ", "randomize failed")
    finish_item(t);
    resp = t.resp;
  endtask

  task read(input bit [31:0] addr, output bit [31:0] data, output axi_lite_resp_e resp);
    axi_lite_item t = axi_lite_item::type_id::create("rd");
    start_item(t);
    if (!t.randomize() with { kind == AXI_READ; addr == local::addr; dly_mode == local::dly_mode; })
      `uvm_fatal("SEQ", "randomize failed")
    finish_item(t);
    data = t.data;
    resp = t.resp;
  endtask

endclass

// -----------------------------------------------------------------------------
class axi_lite_single_write_seq extends axi_lite_base_seq;
  `uvm_object_utils(axi_lite_single_write_seq)
  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit [3:0]  strb;
  axi_lite_resp_e resp;
  constraint c_addr { addr[1:0] == 0; soft strb == 4'hF; }
  function new(string name = "axi_lite_single_write_seq"); super.new(name); endfunction
  task body();
    write(addr, data, resp, strb);
  endtask
endclass

class axi_lite_single_read_seq extends axi_lite_base_seq;
  `uvm_object_utils(axi_lite_single_read_seq)
  rand bit [31:0] addr;
  bit [31:0]      data;
  axi_lite_resp_e resp;
  constraint c_addr { addr[1:0] == 0; }
  function new(string name = "axi_lite_single_read_seq"); super.new(name); endfunction
  task body();
    read(addr, data, resp);
  endtask
endclass

// -----------------------------------------------------------------------------
// Back-to-back: zero delays on every channel, no idle cycles between items.
class axi_lite_b2b_seq extends axi_lite_base_seq;
  `uvm_object_utils(axi_lite_b2b_seq)

  typedef enum { B2B_WRITES, B2B_READS, B2B_ALTERNATE, B2B_WR_THEN_RD } b2b_mode_e;
  rand b2b_mode_e   mode;
  rand int unsigned n;
  bit [31:0]        addrs[$];       // cycled through; must be supplied
  constraint c_n { n inside {[2:16]}; }

  function new(string name = "axi_lite_b2b_seq");
    super.new(name);
    dly_mode = AXI_DLY_ZERO;
  endfunction

  task body();
    axi_lite_resp_e r;
    bit [31:0] d;
    if (addrs.size() == 0) `uvm_fatal("SEQ", "axi_lite_b2b_seq: no addresses")
    for (int i = 0; i < n; i++) begin
      bit [31:0] a = addrs[i % addrs.size()];
      case (mode)
        B2B_WRITES:    write(a, $urandom, r);
        B2B_READS:     read(a, d, r);
        B2B_ALTERNATE: if (i % 2) read(a, d, r); else write(a, $urandom, r);
        B2B_WR_THEN_RD: begin write(a, $urandom, r); read(a, d, r); end
      endcase
    end
  endtask
endclass

// -----------------------------------------------------------------------------
// Random traffic over caller-supplied address ranges.
class axi_lite_rand_seq extends axi_lite_base_seq;
  `uvm_object_utils(axi_lite_rand_seq)

  rand int unsigned n;
  int unsigned      wr_pct = 50;
  bit               partial_strb = 1;   // allow byte strobes other than 4'hF
  bit [31:0]        lo[$];              // inclusive range bounds
  bit [31:0]        hi[$];
  constraint c_n { n inside {[10:50]}; }

  function new(string name = "axi_lite_rand_seq");
    super.new(name);
  endfunction

  function void add_range(bit [31:0] l, bit [31:0] h);
    lo.push_back(l);
    hi.push_back(h);
  endfunction

  task body();
    if (lo.size() == 0) add_range(32'h0, 32'hFFFF_FFFC);
    for (int i = 0; i < n; i++) begin
      axi_lite_item t = axi_lite_item::type_id::create("rnd");
      int unsigned  k = $urandom_range(lo.size() - 1);
      bit [31:0]    a = (lo[k] + ($urandom_range((hi[k] - lo[k]) / 4) * 4));
      bit           w = ($urandom_range(99) < wr_pct);
      start_item(t);
      if (!t.randomize() with { addr == a;
                                kind == (w ? AXI_WRITE : AXI_READ);
                                dly_mode == local::dly_mode;
                                (!local::partial_strb) -> strb == 4'hF;
                                strb dist { 4'hF := 8, [4'h0:4'hE] :/ 2 }; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(t);
    end
  endtask
endclass

// -----------------------------------------------------------------------------
// Error-response sequence: issues reads/writes to caller-supplied addresses
// that are expected to fail and counts responses. Checking whether a given
// response is correct is the scoreboard's job; this sequence only reports
// what it saw so tests can assert that errors were really provoked.
class axi_lite_err_seq extends axi_lite_base_seq;
  `uvm_object_utils(axi_lite_err_seq)

  bit [31:0]   addrs[$];
  int unsigned reps = 1;
  int unsigned n_okay, n_slverr, n_decerr;

  function new(string name = "axi_lite_err_seq");
    super.new(name);
  endfunction

  task body();
    axi_lite_resp_e r;
    bit [31:0] d;
    foreach (addrs[i]) begin
      repeat (reps) begin
        if ($urandom_range(1)) write(addrs[i], $urandom, r);
        else                   read(addrs[i], d, r);
        case (r)
          AXI_OKAY:   n_okay++;
          AXI_SLVERR: n_slverr++;
          AXI_DECERR: n_decerr++;
          default: ;
        endcase
      end
    end
    `uvm_info("ERRSEQ", $sformatf("responses: OKAY=%0d SLVERR=%0d DECERR=%0d",
                                  n_okay, n_slverr, n_decerr), UVM_MEDIUM)
  endtask
endclass
