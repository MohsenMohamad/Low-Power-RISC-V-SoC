// -----------------------------------------------------------------------------
// aon_uart - always-on UART (8N1) with TX/RX FIFOs
//
//   0x00 TXDATA  W   [7:0] push to TX FIFO (dropped if full); R: [31] TX full
//   0x04 RXDATA  R   [7:0] data, [31] RX empty; reading pops one entry
//   0x08 STATUS  R   [0] TX full, [1] TX idle (FIFO empty and shifter idle),
//                    [2] RX valid, [3] RX overrun (W1C)
//   0x0C CTRL    RW  [15:0] DIV (clk_aon cycles per bit, >= 2),
//                    [16] RX irq enable, [17] TX-idle irq enable
// rx_i is asynchronous and is synchronized with tech_sync.
// -----------------------------------------------------------------------------
module aon_uart #(
  parameter int FIFO_DEPTH = 8,
  parameter logic [15:0] DIV_RESET = 16'd8
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        rx_i,
  output logic        tx_o,
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
  logic [15:0] div_q;
  logic        rx_ie_q, tx_ie_q, overrun_q;

  // ---------------- TX ----------------
  logic       txf_push, txf_pop, txf_empty, txf_full;
  logic [7:0] txf_rdata;
  logic [9:0] tx_shift_q;
  logic [3:0] tx_bits_q;
  logic [15:0] tx_cnt_q;
  logic       tx_busy;

  assign tx_busy  = (tx_bits_q != 0);
  assign txf_push = req_i && we_i && (addr_i[11:2] == 10'h0) && wstrb_i[0];
  assign txf_pop  = !tx_busy && !txf_empty;

  fifo_sync #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk_i, .rst_ni, .push_i (txf_push), .wdata_i (wdata_i[7:0]), .pop_i (txf_pop),
    .rdata_o (txf_rdata), .empty_o (txf_empty), .full_o (txf_full)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_shift_q <= '1;
      tx_bits_q  <= '0;
      tx_cnt_q   <= '0;
    end else if (txf_pop) begin
      tx_shift_q <= {1'b1, txf_rdata, 1'b0};
      tx_bits_q  <= 4'd10;
      tx_cnt_q   <= div_q - 16'd1;
    end else if (tx_busy) begin
      if (tx_cnt_q == 0) begin
        tx_shift_q <= {1'b1, tx_shift_q[9:1]};
        tx_bits_q  <= tx_bits_q - 4'd1;
        tx_cnt_q   <= div_q - 16'd1;
      end else begin
        tx_cnt_q <= tx_cnt_q - 16'd1;
      end
    end
  end
  assign tx_o = tx_busy ? tx_shift_q[0] : 1'b1;

  // ---------------- RX ----------------
  logic       rx_s;
  logic       rx_active_q;
  logic [15:0] rx_cnt_q;
  logic [3:0] rx_bits_q;
  logic [8:0] rx_shift_q;
  logic       rxf_push, rxf_pop, rxf_empty, rxf_full;
  logic [7:0] rxf_rdata;

  tech_sync #(.WIDTH(1), .STAGES(2), .RESET_VAL(1'b1)) u_rx_sync (
    .clk_i, .rst_ni, .d_i (rx_i), .q_o (rx_s)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_active_q <= 1'b0;
      rx_cnt_q    <= '0;
      rx_bits_q   <= '0;
      rx_shift_q  <= '0;
    end else if (!rx_active_q) begin
      if (!rx_s) begin               // start bit edge: sample at mid-bit
        rx_active_q <= 1'b1;
        rx_cnt_q    <= {1'b0, div_q[15:1]};
        rx_bits_q   <= 4'd0;
      end
    end else if (rx_cnt_q == 0) begin
      rx_cnt_q <= div_q - 16'd1;
      if (rx_bits_q == 4'd0 && rx_s) begin
        rx_active_q <= 1'b0;         // false start
      end else begin
        rx_shift_q <= {rx_s, rx_shift_q[8:1]};
        rx_bits_q  <= rx_bits_q + 4'd1;
        if (rx_bits_q == 4'd9) rx_active_q <= 1'b0;
      end
    end else begin
      rx_cnt_q <= rx_cnt_q - 16'd1;
    end
  end

  // Byte complete when the stop bit (bit 9) is sampled high.
  assign rxf_push = rx_active_q && (rx_cnt_q == 0) && (rx_bits_q == 4'd9) && rx_s;
  assign rxf_pop  = req_i && !we_i && (addr_i[11:2] == 10'h1);

  fifo_sync #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk_i, .rst_ni, .push_i (rxf_push), .wdata_i (rx_shift_q[8:1]), .pop_i (rxf_pop),
    .rdata_o (rxf_rdata), .empty_o (rxf_empty), .full_o (rxf_full)
  );

  // ---------------- registers ----------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_q     <= DIV_RESET;
      rx_ie_q   <= 1'b0;
      tx_ie_q   <= 1'b0;
      overrun_q <= 1'b0;
    end else begin
      if (rxf_push && rxf_full) overrun_q <= 1'b1;
      if (req_i && we_i) begin
        case (addr_i[11:2])
          10'h2: if (wstrb_i[0] && wdata_i[3]) overrun_q <= 1'b0;
          10'h3: begin
            if (wstrb_i[0]) div_q[7:0]  <= wdata_i[7:0];
            if (wstrb_i[1]) div_q[15:8] <= wdata_i[15:8];
            if (wstrb_i[2]) begin rx_ie_q <= wdata_i[16]; tx_ie_q <= wdata_i[17]; end
          end
          default: ;
        endcase
      end
    end
  end

  logic tx_idle;
  assign tx_idle = txf_empty && !tx_busy;
  assign irq_o   = (rx_ie_q && !rxf_empty) || (tx_ie_q && tx_idle);
  assign ack_o   = req_i;

  logic unused;
  assign unused = ^{addr_i[1:0], wdata_i[31:18], wstrb_i[3], rx_shift_q[0]};

  always_comb begin
    rdata_o = '0;
    err_o   = 1'b0;
    case (addr_i[11:2])
      10'h0: rdata_o = {txf_full, 31'b0};
      10'h1: begin rdata_o = {rxf_empty, 23'b0, rxf_rdata}; err_o = we_i; end
      10'h2: rdata_o = {28'b0, overrun_q, !rxf_empty, tx_idle, txf_full};
      10'h3: rdata_o = {14'b0, tx_ie_q, rx_ie_q, div_q};
      default: err_o = 1'b1;
    endcase
  end
endmodule
