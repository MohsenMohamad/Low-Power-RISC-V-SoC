// -----------------------------------------------------------------------------
// dvfs_clk_mux - N-input glitch-free clock multiplexer (DVFS operating points)
//
// The N source clocks may be mutually asynchronous. For each branch i:
//   req_i   = (sel == i) and no other branch reports active (synchronized
//             into clk_i)
//   en_q[i] = req_i through a STAGES-flop synchronizer on posedge clk_i
//   en_n[i] = en_q[i] re-timed on negedge clk_i
//   gated   = ICG(clk_i, en_n[i])  (enable changes only while clk_i is low)
//   active[i] = en_q[i] | en_n[i]  (drops only after the branch is fully off)
// A branch therefore only starts after every other branch has stopped on a
// low phase, so the OR of the gated clocks never contains a runt pulse,
// independent of the frequency ratio.
// active_o[i] (status for the PMU, which synchronizes it) is set only when
// branch i is enabled AND every other branch's synchronizer has observed it
// active. Only then may sel_i change again: otherwise a branch could still
// hold a stale "all others off" view and start while branch i is running
// (found by formal/dvfs_mux.sby).
// sel_i must only change when active_o == onehot(sel_i) (the PMU waits for
// that), and while the downstream clock is gated.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module dvfs_clk_mux #(
  parameter int         N         = 3,
  parameter int         STAGES    = 2,
  parameter logic [1:0] RESET_SEL = 2'd0
) (
  input  logic [N-1:0] clk_i,
  input  logic         rst_ni,     // asynchronous, de-asserted while sources run
  input  logic [1:0]   sel_i,
  input  logic         test_en_i,
  output logic         clk_o,
  output logic [N-1:0] active_o
);
  logic [N-1:0] en_q, en_n, gclk;
  logic [N-1:0] active;
  logic [N-1:0] osync [N];   // osync[i][j]: branch i's view of branch j
  logic [N-1:0] seen_all;    // branch j seen active by every other branch

  assign active = en_q | en_n;

  always_comb begin
    for (int j = 0; j < N; j++) begin
      seen_all[j] = 1'b1;
      for (int i = 0; i < N; i++)
        if (i != j) seen_all[j] = seen_all[j] & osync[i][j];
    end
  end
  assign active_o = en_n & seen_all;

  for (genvar i = 0; i < N; i++) begin : g_branch
    logic [N-1:0] others_sync;
    logic         others_active;
    logic         req;
    logic         rst_n;

    // Per-branch reset with de-assertion synchronous to clk_i[i].
    rst_sync u_rst_sync (.clk_i (clk_i[i]), .arst_ni (rst_ni), .rst_no (rst_n));

    // Status of all other branches, synchronized into clk_i[i].
    tech_sync #(.WIDTH(N), .STAGES(STAGES), .RESET_VAL(N'(1) << RESET_SEL)) u_sync_others (
      .clk_i  (clk_i[i]),
      .rst_ni (rst_n),
      .d_i    (active),
      .q_o    (others_sync)
    );
    assign osync[i] = others_sync;

    always_comb begin
      others_active = 1'b0;
      for (int j = 0; j < N; j++)
        if (j != i) others_active = others_active | others_sync[j];
    end

    assign req = (sel_i == 2'(i)) && !others_active;

    // Enable synchronizer (sel_i is asynchronous to clk_i[i]).
    tech_sync #(.WIDTH(1), .STAGES(STAGES), .RESET_VAL(1'((RESET_SEL == 2'(i)) ? 1 : 0))) u_sync_en (
      .clk_i  (clk_i[i]),
      .rst_ni (rst_n),
      .d_i    (req),
      .q_o    (en_q[i])
    );

    logic en_neg_q;
    always_ff @(negedge clk_i[i] or negedge rst_n) begin
      if (!rst_n) en_neg_q <= (RESET_SEL == 2'(i));
      else        en_neg_q <= en_q[i];
    end
    assign en_n[i] = en_neg_q;

    tech_clk_gate u_cg (
      .clk_i     (clk_i[i]),
      .en_i      (en_n[i]),
      .test_en_i (1'b0),
      .clk_o     (gclk[i])
    );
  end

  tech_clk_or #(.N(N)) u_or (.clk_i (gclk), .clk_o (clk_o));

  logic unused;
  assign unused = test_en_i;

  // Glitch-freedom invariant: at most one branch enabled at any time.
  // (Sampled on the output clock here; formal/dvfs_mux.sby checks the full
  // property at every step with arbitrary, unrelated source clocks.)
  `SVA_ASSERT(a_onehot_en, clk_o, rst_ni, $onehot0(en_n))

`ifdef FORMAL_MULTICLOCK
  // Checked at every solver step with free-running, unrelated source clocks
  // (formal/dvfs_mux.sby, multiclock on). Only after reset: at power-up the
  // ICG latches hold random values until their clock first goes low.
  logic f_init = 1'b1;
  logic f_rst_done = 1'b0;
  always @($global_clock) begin
    f_init <= 1'b0;
    if (f_init || !rst_ni) f_rst_done <= 1'b0;
    else if (g_branch[0].rst_n && g_branch[1].rst_n && g_branch[2].rst_n && !(|clk_i))
      f_rst_done <= 1'b1;
  end
  always @($global_clock) if (!f_init && f_rst_done && $past(f_rst_done)) begin
    // gated branch clocks never rise or fall except with their source
    if (gclk[0] && !$past(gclk[0])) f_rise0: assert (clk_i[0] && !$past(clk_i[0]));
    if (gclk[1] && !$past(gclk[1])) f_rise1: assert (clk_i[1] && !$past(clk_i[1]));
    if (gclk[2] && !$past(gclk[2])) f_rise2: assert (clk_i[2] && !$past(clk_i[2]));
    if (!gclk[0] && $past(gclk[0])) f_fall0: assert (!clk_i[0] && $past(clk_i[0]));
    if (!gclk[1] && $past(gclk[1])) f_fall1: assert (!clk_i[1] && $past(clk_i[1]));
    if (!gclk[2] && $past(gclk[2])) f_fall2: assert (!clk_i[2] && $past(clk_i[2]));
    // a branch only starts after every branch was low (no merged pulses)
    if (|(gclk & ~$past(gclk))) f_gap: assert ($past(gclk) == '0);
    f_onehot: assert ($onehot0(gclk));
    f_onehot_en: assert ($onehot0(en_n));
  end
`endif
endmodule
