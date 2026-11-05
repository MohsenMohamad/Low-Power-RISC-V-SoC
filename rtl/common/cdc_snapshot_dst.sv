// cdc_snapshot_dst - destination half; protocol description in cdc_snapshot_src.sv
module cdc_snapshot_dst #(
  parameter int W = 64
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [W-1:0] snap_i,      // from source, stable when ack observed
  input  logic         ack_tgl_i,   // asynchronous
  output logic         req_tgl_o,
  output logic [W-1:0] value_o,
  output logic         valid_o      // at least one fresh snapshot captured
);
  logic ack_s, req_q, primed_q, valid_q;
  logic [W-1:0] value_q;

  tech_sync #(.WIDTH(1), .STAGES(2)) u_ack_sync (
    .clk_i, .rst_ni, .d_i (ack_tgl_i), .q_o (ack_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q    <= 1'b0;
      primed_q <= 1'b0;
      valid_q  <= 1'b0;
      value_q  <= '0;
    end else if (ack_s == req_q) begin
      // Handshake complete: snap_i has been stable since before ack toggled.
      if (primed_q) begin
        value_q <= snap_i;
        valid_q <= 1'b1;
      end
      primed_q <= 1'b1;
      req_q    <= ~req_q;
    end
  end

  assign req_tgl_o = req_q;
  assign value_o   = value_q;
  assign valid_o   = valid_q;
endmodule
