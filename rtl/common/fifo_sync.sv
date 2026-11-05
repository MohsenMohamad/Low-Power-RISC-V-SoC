// -----------------------------------------------------------------------------
// fifo_sync - single-clock FIFO (power-of-two depth)
// -----------------------------------------------------------------------------
module fifo_sync #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 8
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             push_i,
  input  logic [WIDTH-1:0] wdata_i,
  input  logic             pop_i,
  output logic [WIDTH-1:0] rdata_o,
  output logic             empty_o,
  output logic             full_o
);
  localparam int AW = $clog2(DEPTH);
  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0]      wptr_q, rptr_q;

  assign empty_o = (wptr_q == rptr_q);
  assign full_o  = (wptr_q[AW-1:0] == rptr_q[AW-1:0]) && (wptr_q[AW] != rptr_q[AW]);
  assign rdata_o = mem[rptr_q[AW-1:0]];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
      rptr_q <= '0;
    end else begin
      if (push_i && !full_o)  wptr_q <= wptr_q + 1'b1;
      if (pop_i  && !empty_o) rptr_q <= rptr_q + 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (push_i && !full_o) mem[wptr_q[AW-1:0]] <= wdata_i;
  end
endmodule
