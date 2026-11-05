// Simulation bridge: connects a UART TX/RX pin pair of a Verilator model to
// a host pseudo-terminal (uart_pty.c), so the bench scripts open the
// simulation exactly like a serial port. Bit timing: DIV clock cycles per
// bit, 8N1. Reusable with any SoC top that exposes UART pins.
//   +pty            enable (otherwise RX idles high and TX is only logged)
//   +pty_file=<f>   write the pty path to <f>
module dbg_uart_pty_bridge #(
  parameter int unsigned DIV = 8,
  parameter int unsigned RX_GAP = 4      // idle bit times between RX bytes
) (
  input  logic clk,
  input  logic uart_txd,      // from the DUT
  output logic uart_rxd       // to the DUT
);
  import "DPI-C" function int dbg_pty_open(input string path_file);
  import "DPI-C" function int dbg_pty_getc();
  import "DPI-C" function void dbg_pty_putc(input int c);

  bit enabled = 1'b0;
  initial begin
    string f = "";
    if ($test$plusargs("pty")) begin
      void'($value$plusargs("pty_file=%s", f));
      enabled = (dbg_pty_open(f) == 0);
    end
  end

  // ---- TX: DUT -> pty ----
  typedef enum logic [1:0] {T_IDLE, T_START, T_DATA, T_STOP} tst_t;
  tst_t        tst = T_IDLE;
  int unsigned tcnt = 0, tbit = 0;
  logic [7:0]  tsh = '0;
  always_ff @(posedge clk) begin
    unique case (tst)
      T_IDLE:  if (!uart_txd) begin tst <= T_START; tcnt <= 0; end
      T_START: if (tcnt == DIV / 2 - 1) begin tcnt <= 0; tbit <= 0; tst <= uart_txd ? T_IDLE : T_DATA; end
               else tcnt <= tcnt + 1;
      T_DATA:  if (tcnt == DIV - 1) begin
                 tcnt <= 0; tsh <= {uart_txd, tsh[7:1]};
                 if (tbit == 7) tst <= T_STOP; else tbit <= tbit + 1;
               end else tcnt <= tcnt + 1;
      T_STOP:  if (tcnt == DIV - 1) begin
                 tcnt <= 0; tst <= T_IDLE;
                 if (enabled) dbg_pty_putc(int'(tsh));
               end else tcnt <= tcnt + 1;
      default: tst <= T_IDLE;
    endcase
  end

  // ---- RX: pty -> DUT ----
  logic [9:0]  rsh = '1;
  int unsigned rcnt = 0, rbit = 0, poll = 0;
  logic        busy = 1'b0;
  assign uart_rxd = busy ? rsh[0] : 1'b1;
  always_ff @(posedge clk) begin
    if (!busy) begin
      // poll the host every 64 cycles (keeps the DPI overhead low)
      poll <= poll + 1;
      if (enabled && poll[5:0] == 0) begin
        automatic int c = dbg_pty_getc();
        if (c >= 0) begin
          rsh <= {1'b1, 8'(c), 1'b0}; busy <= 1'b1; rcnt <= 0; rbit <= 0;
        end
      end
    end else if (rcnt == DIV - 1) begin
      rcnt <= 0; rsh <= {1'b1, rsh[9:1]};
      if (rbit == 9 + RX_GAP) busy <= 1'b0; else rbit <= rbit + 1;
    end else rcnt <= rcnt + 1;
  end
endmodule
