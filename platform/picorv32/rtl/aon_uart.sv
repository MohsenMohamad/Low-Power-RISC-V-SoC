// UART, 8N1, 16-entry TX and RX FIFOs (PD_AON).
//
// Registers (word offsets from base):
//   0x00 DATA    W: push TX byte. R: pop RX byte ([7:0]; 0 if empty)
//   0x04 STATUS  [0] TX_FULL [1] TX_IDLE (FIFO empty, shifter idle)
//                [2] RX_AVAIL [3] RX_OVERRUN (write 1 to clear)
//   0x08 IE      [0] RX_AVAIL interrupt  [1] TX_IDLE interrupt
//   0x0C DIV     clk_aon cycles per bit (reset value = DIV_RESET)
// Peripheral port: 'req' is a one-cycle strobe, 'rdata' is valid the cycle
// after the strobe.
module aon_uart #(
    parameter logic [15:0] DIV_RESET = 16'd8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req,
    input  logic        we,
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [11:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [31:0] wdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] rdata,
    output logic        irq,
    input  logic        rxd,
    output logic        txd
);
    localparam int D = 16;

    logic [15:0] div;
    logic [1:0]  ie;
    logic        overrun;

    // ---------------- TX ----------------
    logic [7:0] txf [D];
    logic [4:0] tx_wp, tx_rp;
    wire  [4:0] tx_cnt = tx_wp - tx_rp;
    wire        tx_full = (tx_cnt == 5'(D));
    logic [9:0] tx_sh;
    logic [3:0] tx_bits;
    logic [15:0] tx_tmr;
    wire        tx_busy = (tx_bits != 0);

    // ---------------- RX ----------------
    logic [7:0] rxf [D];
    logic [4:0] rx_wp, rx_rp;
    wire  [4:0] rx_cnt = rx_wp - rx_rp;
    logic rxd_s;
    logic [3:0]  rx_bits;
    logic [15:0] rx_tmr;
    logic [7:0]  rx_sh;

    tc_sync #(.RESET_VAL(1'b1)) u_rxs (.clk(clk), .rst_n(rst_n), .d(rxd), .q(rxd_s));

    wire wr_data = req && we && addr[3:2] == 2'd0;
    wire rd_data = req && !we && addr[3:2] == 2'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= DIV_RESET; ie <= '0; overrun <= 1'b0;
            tx_wp <= '0; tx_rp <= '0; tx_sh <= '1; tx_bits <= '0; tx_tmr <= '0;
            rx_wp <= '0; rx_rp <= '0; rx_bits <= '0; rx_tmr <= '0; rx_sh <= '0;
            rdata <= '0;
        end else begin
            // register access
            if (req) begin
                if (we) begin
                    unique case (addr[3:2])
                        2'd0: if (!tx_full) begin txf[tx_wp[3:0]] <= wdata[7:0]; tx_wp <= tx_wp + 1'b1; end
                        2'd1: if (wdata[3]) overrun <= 1'b0;
                        2'd2: ie <= wdata[1:0];
                        2'd3: div <= (wdata[15:0] < 16'd4) ? 16'd4 : wdata[15:0];
                    endcase
                end else begin
                    unique case (addr[3:2])
                        2'd0: rdata <= (rx_cnt != 0) ? {24'd0, rxf[rx_rp[3:0]]} : 32'd0;
                        2'd1: rdata <= {28'd0, overrun, (rx_cnt != 0), (!tx_busy && tx_cnt == 0), tx_full};
                        2'd2: rdata <= {30'd0, ie};
                        2'd3: rdata <= {16'd0, div};
                    endcase
                end
            end
            if (rd_data && rx_cnt != 0) rx_rp <= rx_rp + 1'b1;

            // transmitter
            if (tx_busy) begin
                if (tx_tmr == div - 1'b1) begin
                    tx_tmr  <= '0;
                    tx_sh   <= {1'b1, tx_sh[9:1]};
                    tx_bits <= tx_bits - 1'b1;
                end else tx_tmr <= tx_tmr + 1'b1;
            end else if (tx_cnt != 0 && !wr_data) begin
                tx_sh   <= {1'b1, txf[tx_rp[3:0]], 1'b0};
                tx_rp   <= tx_rp + 1'b1;
                tx_bits <= 4'd10;
                tx_tmr  <= '0;
            end

            // receiver: start bit, sample in the middle of each bit
            if (rx_bits == 0) begin
                if (!rxd_s) begin
                    rx_bits <= 4'd10;
                    rx_tmr  <= {1'b0, div[15:1]};
                end
            end else if (rx_tmr == div - 1'b1) begin
                rx_tmr <= '0;
                rx_bits <= rx_bits - 1'b1;
            end else rx_tmr <= rx_tmr + 1'b1;

            if (rx_bits != 0 && rx_tmr == div - 1'b1) begin
                // rx_bits 10: middle of start bit .. 1: middle of stop bit
                if (rx_bits == 4'd10 && rxd_s) rx_bits <= '0;           // false start
                else if (rx_bits <= 4'd9 && rx_bits >= 4'd2) rx_sh <= {rxd_s, rx_sh[7:1]};
                else if (rx_bits == 4'd1) begin
                    if (rxd_s) begin
                        if (rx_cnt == 5'(D)) overrun <= 1'b1;
                        else begin
                            rxf[rx_wp[3:0]] <= rx_sh;
                            rx_wp <= rx_wp + 1'b1;
                        end
                    end
                end
            end
        end
    end

    assign txd = tx_sh[0] | !tx_busy;
    assign irq = (ie[0] && rx_cnt != 0) || (ie[1] && !tx_busy && tx_cnt == 0);
endmodule
