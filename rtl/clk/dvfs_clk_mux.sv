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
// independent of the frequency ratio. active_o is the per-branch status (each
// bit in its own clock domain) for the PMU, which synchronizes it.
// sel_i must be quasi-static (changed only by the PMU while the downstream
// clock is gated).
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

  assign active   = en_q | en_n;
  assign active_o = active;

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
  // (Checked in formal with multiclock; here sampled on every source edge.)
  for (genvar i = 0; i < N; i++) begin : g_sva
    `SVA_ASSERT(a_onehot_en, clk_i[i], rst_ni, $onehot0(en_n))
  end
endmodule
