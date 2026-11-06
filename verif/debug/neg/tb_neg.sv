// Negative tests of the debug verification checkers (doc/SPEC.md: every
// checker has a negative test that proves it reports failure on wrong input).
// Each test feeds a checker deliberately wrong input; the run must FAIL
// (scripts/run_dbg.py records it as passed only if the expected failure is
// reported).
//
// Tests (+TEST=<name>):
//   neg_axil_rst   dbg_axil_sva: a slave that holds BVALID and RVALID high
//                  during the whole reset. a_rst_valid must fire. (Before the
//                  fix the assertion was disabled by "disable iff (!rst_n)",
//                  the very condition it checks, and stayed silent.)
`timescale 1ns/1ps
module tb_neg;
  import dbg_tb_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  string test = "neg_axil_rst";

  // broken slave: response valids stuck high
  logic        bvalid = 1'b1, rvalid = 1'b1;
  logic [1:0]  bresp = 2'b00, rresp = 2'b00;
  logic [31:0] rdata = '0;

  dbg_axil_sva #(.AW(12), .ONE_CYCLE(1'b0)) u_sva (
    .clk(clk), .rst_n(rst_n),
    .awaddr('0), .awvalid(1'b0), .awready(1'b1),
    .wdata('0), .wstrb('0), .wvalid(1'b0), .wready(1'b1),
    .bresp(bresp), .bvalid(bvalid), .bready(1'b0),
    .araddr('0), .arvalid(1'b0), .arready(1'b1),
    .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(1'b0));

  initial begin
    void'($value$plusargs("TEST=%s", test));
    $display("tb_neg: NEGATIVE TEST %s", test);
    case (test)
      "neg_axil_rst": begin
        // reset held for 20 cycles with both response valids high, then the
        // slave behaves (valids low) after reset
        repeat (20) @(posedge clk);
        @(negedge clk) begin rst_n = 1'b1; bvalid = 1'b0; rvalid = 1'b0; end
        repeat (10) @(posedge clk);
      end
      default: $fatal(1, "unknown test %s", test);
    endcase
    check(1'b1, "stimulus applied");
    report(test, 0);
    $finish;
  end
endmodule
