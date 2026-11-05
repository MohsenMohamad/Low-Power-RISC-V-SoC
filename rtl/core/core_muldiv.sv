// M-extension unit.
//   * MUL/MULH/MULHSU/MULHU : single-cycle 33x33 signed multiplier (combinational)
//   * DIV/DIVU/REM/REMU     : radix-2 restoring divider, 32 iterations + 1 setup
//                             cycle; divide-by-zero and signed overflow complete in
//                             one cycle with the ISA-defined results.
// The divider holds `done` until `ack` (the EX stage advancing) is seen.
module core_muldiv (
  input  logic        clk,
  input  logic        rst_n,
  // multiply (combinational)
  input  logic [2:0]  mul_op,
  input  logic [31:0] mul_a,
  input  logic [31:0] mul_b,
  output logic [31:0] mul_y,
  // divide (sequential)
  input  logic        div_start,   // pulse/level while idle: latch operands
/* verilator lint_off UNUSEDSIGNAL */ // funct3[2] is always 1 for divides
  input  logic [2:0]  div_op,      // funct3: 100 DIV, 101 DIVU, 110 REM, 111 REMU
/* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] div_a,
  input  logic [31:0] div_b,
  input  logic        div_ack,     // consumer took the result
  input  logic        div_kill,    // abandon any operation (pipeline flush)
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] div_y
);

  // ---------------------------------------------------------------------------
  // Multiplier
  // ---------------------------------------------------------------------------
  logic signed [32:0] ma, mb;
/* verilator lint_off UNUSEDSIGNAL */ // sign-extension bits of the 66-bit product
  logic signed [65:0] mp;
/* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    ma = {(mul_op == 3'b001 || mul_op == 3'b010) ? mul_a[31] : 1'b0, mul_a};
    mb = {(mul_op == 3'b001) ? mul_b[31] : 1'b0, mul_b};
    mp = ma * mb;
    mul_y = (mul_op == 3'b000) ? mp[31:0] : mp[63:32];
  end

  // ---------------------------------------------------------------------------
  // Divider
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { D_IDLE, D_RUN, D_DONE } dstate_e;
  dstate_e     state_q;
  logic [31:0] quot_q, rem_q, divisor_q;
  logic [5:0]  cnt_q;
  logic        neg_q_q, neg_r_q, is_rem_q;
  logic [31:0] result_q;

  logic        is_signed;
  logic [31:0] abs_a, abs_b;
  logic [32:0] rem_shift, rem_sub;

  assign is_signed = !div_op[0];
  assign abs_a = (is_signed && div_a[31]) ? (~div_a + 32'd1) : div_a;
  assign abs_b = (is_signed && div_b[31]) ? (~div_b + 32'd1) : div_b;

  assign rem_shift = {rem_q, quot_q[31]};
  assign rem_sub   = rem_shift - {1'b0, divisor_q};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= D_IDLE;
      quot_q    <= '0;
      rem_q     <= '0;
      divisor_q <= '0;
      cnt_q     <= '0;
      neg_q_q   <= 1'b0;
      neg_r_q   <= 1'b0;
      is_rem_q  <= 1'b0;
      result_q  <= '0;
    end else if (div_kill) begin
      state_q <= D_IDLE;
    end else begin
      unique case (state_q)
        D_IDLE: if (div_start) begin
          is_rem_q <= div_op[1];
          if (div_b == 32'd0) begin
            // x/0 = all ones, x%0 = x
            result_q <= div_op[1] ? div_a : 32'hFFFF_FFFF;
            state_q  <= D_DONE;
          end else if (is_signed && div_a == 32'h8000_0000 && div_b == 32'hFFFF_FFFF) begin
            // signed overflow: quotient = -2^31, remainder = 0
            result_q <= div_op[1] ? 32'd0 : 32'h8000_0000;
            state_q  <= D_DONE;
          end else begin
            quot_q    <= abs_a;
            rem_q     <= '0;
            divisor_q <= abs_b;
            cnt_q     <= 6'd32;
            neg_q_q   <= is_signed && (div_a[31] ^ div_b[31]);
            neg_r_q   <= is_signed && div_a[31];
            state_q   <= D_RUN;
          end
        end
        D_RUN: begin
          if (!rem_sub[32]) begin
            rem_q  <= rem_sub[31:0];
            quot_q <= {quot_q[30:0], 1'b1};
          end else begin
            rem_q  <= rem_shift[31:0];
            quot_q <= {quot_q[30:0], 1'b0};
          end
          cnt_q <= cnt_q - 6'd1;
          if (cnt_q == 6'd1) state_q <= D_DONE;
        end
        D_DONE: if (div_ack) state_q <= D_IDLE;
        default: state_q <= D_IDLE;
      endcase

      // Final sign fix-up: computed on the cycle the last iteration lands.
      if (state_q == D_RUN && cnt_q == 6'd1) begin
        if (is_rem_q) begin
          logic [31:0] r;
          r = (!rem_sub[32]) ? rem_sub[31:0] : rem_shift[31:0];
          result_q <= neg_r_q ? (~r + 32'd1) : r;
        end else begin
          logic [31:0] q;
          q = {quot_q[30:0], !rem_sub[32]};
          result_q <= neg_q_q ? (~q + 32'd1) : q;
        end
      end
    end
  end

  assign div_busy = (state_q == D_RUN);
  assign div_done = (state_q == D_DONE);
  assign div_y    = result_q;

endmodule
