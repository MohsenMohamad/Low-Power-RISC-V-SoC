// -----------------------------------------------------------------------------
// aon_wake_timer - always-on down-counting wake-up timer
//
//   0x00 CTRL   RW  [0] EN, [1] PERIODIC (reload from LOAD on expiry)
//   0x04 LOAD   RW  start value (writing LOAD also restarts COUNT)
//   0x08 COUNT  RO  current value
//   0x0C STATUS W1C [0] EXPIRED
// irq_o = EXPIRED (routed to the interrupt controller -> PMU wake).
// -----------------------------------------------------------------------------
module aon_wake_timer (
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic        irq_o,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [11:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic [3:0]  wstrb_i,
  output logic        ack_o,
  output logic [31:0] rdata_o,
  output logic        err_o
);
  logic        en_q, periodic_q, expired_q;
  logic [31:0] load_q, count_q;
  logic        wr;

  assign wr    = req_i && we_i && (wstrb_i == 4'hF);
  assign ack_o = req_i;
  assign irq_o = expired_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q       <= 1'b0;
      periodic_q <= 1'b0;
      expired_q  <= 1'b0;
      load_q     <= '0;
      count_q    <= '0;
    end else begin
      if (en_q) begin
        if (count_q == 32'd0) begin
          expired_q <= 1'b1;
          if (periodic_q) count_q <= load_q;
          else            en_q    <= 1'b0;
        end else begin
          count_q <= count_q - 32'd1;
        end
      end
      if (wr) begin
        case (addr_i[11:2])
          10'h0: begin
            en_q       <= wdata_i[0];
            periodic_q <= wdata_i[1];
            if (wdata_i[0] && !en_q) count_q <= load_q;
          end
          10'h1: begin load_q <= wdata_i; count_q <= wdata_i; end
          10'h3: if (wdata_i[0]) expired_q <= 1'b0;
          default: ;
        endcase
      end
    end
  end

  logic unused;
  assign unused = ^addr_i[1:0];

  always_comb begin
    rdata_o = '0;
    err_o   = we_i && (wstrb_i != 4'hF);
    case (addr_i[11:2])
      10'h0: rdata_o = {30'b0, periodic_q, en_q};
      10'h1: rdata_o = load_q;
      10'h2: begin rdata_o = count_q; err_o = we_i; end
      10'h3: rdata_o = {31'b0, expired_q};
      default: err_o = 1'b1;
    endcase
  end
endmodule
