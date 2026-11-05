// -----------------------------------------------------------------------------
// async_fifo_formal - SymbiYosys harness for cdc_async_fifo (multiclock)
//
// Write and read clocks are free inputs (arbitrary unrelated frequencies).
// The writer pushes a running sequence number; the reader must receive
// exactly that sequence: no loss, duplication, reordering or corruption,
// and the FIFO never holds more than DEPTH entries.
// -----------------------------------------------------------------------------
module async_fifo_formal (
  input logic wclk_i,
  input logic rclk_i,
  input logic rst_ni,
  input logic wvalid_i,
  input logic rready_i
);
  localparam int W = 8, DEPTH = 4;

  logic         wready, rvalid, w_empty;
  logic [W-1:0] rdata;
  logic [W-1:0] wcnt = '0, rcnt = '0;   // ghost counters

  cdc_async_fifo #(.WIDTH(W), .DEPTH(DEPTH)) dut (
    .wclk_i, .wrst_ni (rst_ni), .wvalid_i, .wready_o (wready), .wdata_i (wcnt),
    .w_empty_o (w_empty),
    .rclk_i, .rrst_ni (rst_ni), .rvalid_o (rvalid), .rready_i, .rdata_o (rdata)
  );

  always @(posedge wclk_i) if (rst_ni && wvalid_i && wready) wcnt <= wcnt + 1'b1;
  always @(posedge rclk_i) if (rst_ni && rvalid && rready_i) rcnt <= rcnt + 1'b1;

  logic init = 1'b1;
  always @($global_clock) begin
    init <= 1'b0;
    if (init) assume (!rst_ni);
    else if ($past(rst_ni)) assume (rst_ni);
  end

  always @($global_clock) if (!init && rst_ni) begin
    if (rvalid)  a_in_order:    assert (rdata == rcnt);
    a_no_overrun: assert (W'(wcnt - rcnt) <= W'(DEPTH));
    if (rvalid)  a_no_underrun: assert (wcnt != rcnt);
    if (w_empty) a_wempty_safe: assert (wcnt == rcnt);
    c_full:  cover (!wready && W'(wcnt - rcnt) == W'(DEPTH));
    c_wrap:  cover (rcnt == W'(2 * DEPTH + 1));
  end
endmodule
