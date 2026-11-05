// -----------------------------------------------------------------------------
// dvfs_mux_formal - SymbiYosys harness for the glitch-free DVFS clock mux
//
// multiclock mode: the three source clocks are free inputs that may toggle at
// any solver step (arbitrary, unrelated frequencies and phases). The select
// changes only after the previous switch has completed (PMU behaviour).
// Properties (in rtl/clk/dvfs_clk_mux.sv, FORMAL_MULTICLOCK), every step:
//   * a gated branch clock rises only with its source rising edge and falls
//     only with its source falling edge (no truncated or runt pulses)
//   * at most one gated branch clock is high
//   * a gated branch clock only starts after all branches were low
//     (no merged pulses on the OR output)
// Cover: the mux reaches every operating point.
// -----------------------------------------------------------------------------
module dvfs_mux_formal (
  input logic [2:0] clk_i,
  input logic       rst_ni,
  input logic [1:0] sel_i
);
  logic       clk_o;
  logic [2:0] active;

  dvfs_clk_mux #(.N(3), .STAGES(2), .RESET_SEL(2'd2)) dut (
    .clk_i, .rst_ni, .sel_i, .test_en_i (1'b0), .clk_o, .active_o (active)
  );

  logic init = 1'b1;
  always @($global_clock) init <= 1'b0;

  // Environment: reset held at start and then released for good; the PMU
  // changes sel only once the mux reports the previous selection.
  always @($global_clock) begin
    assume (sel_i < 2'd3);
    if (init) assume (!rst_ni);
    else begin
      if ($past(rst_ni)) assume (rst_ni);
      if (sel_i != $past(sel_i)) assume ($past(active) == (3'b001 << $past(sel_i)));
    end
  end

  // Reachability of every operating point after a switch.
  always @($global_clock) if (!init && rst_ni) begin
    c_op0: cover (active == 3'b001 && sel_i == 2'd0 && clk_o);
    c_op1: cover (active == 3'b010 && sel_i == 2'd1 && clk_o);
    c_op2_back: cover (active == 3'b100 && sel_i == 2'd2 && clk_o && $past(active) != 3'b100);
  end
endmodule
