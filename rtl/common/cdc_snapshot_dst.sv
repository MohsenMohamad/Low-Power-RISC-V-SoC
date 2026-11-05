// cdc_snapshot_dst - destination half; protocol description in cdc_snapshot_src.sv
module cdc_snapshot_dst #(
  parameter int W      = 64,
  parameter int SETTLE = 3      // > synchronizer depth: ack_s holds real samples
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [W-1:0] snap_i,      // from source, stable while ack is high
  input  logic         ack_i,       // asynchronous
  output logic         req_o,
  output logic [W-1:0] value_o,
  output logic         valid_o      // at least one snapshot captured since reset
);
  logic ack_s, req_q, valid_q;
  logic [1:0] settle_q;
  logic [W-1:0] value_q;

  tech_sync #(.WIDTH(1), .STAGES(2)) u_ack_sync (
    .clk_i, .rst_ni, .d_i (ack_i), .q_o (ack_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q    <= 1'b0;
      valid_q  <= 1'b0;
      value_q  <= '0;
      settle_q <= '0;
    end else if (settle_q != 2'(SETTLE)) begin
      settle_q <= settle_q + 2'd1;
    end else if (!req_q && !ack_s) begin
      req_q <= 1'b1;                    // previous handshake fully closed
    end else if (req_q && ack_s) begin
      value_q <= snap_i;                // stable: source holds it while ack is high
      valid_q <= 1'b1;
      req_q   <= 1'b0;
    end
  end

  assign req_o   = req_q;
  assign value_o = value_q;
  assign valid_o = valid_q;
endmodule
