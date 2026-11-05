// -----------------------------------------------------------------------------
// pmu_formal - SymbiYosys harness for the PMU
//
// All PMU inputs are unconstrained except for the physical behaviour of the
// blocks the PMU talks to (assumptions below). Register writes may happen at
// any time. The PMU's own assertions (rtl/aon/pmu.sv) are the proof
// obligations; its cover points give FSM transition reachability.
// -----------------------------------------------------------------------------
module pmu_formal (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        req_i,
  input logic        we_i,
  input logic [11:0] addr_i,
  input logic [31:0] wdata_i,
  input logic [3:0]  wstrb_i,
  input logic        meip_i,
  input logic        mtip_i,
  input logic        msip_i,
  input logic        core_sleep_i,
  input logic        idle_ack_i,
  input logic        cache_clean_i,
  input logic        cg_ack_i,
  input logic        bus_idle_i,
  input logic        cpu_rst_ack_i,
  input logic        pwr_good_i,
  input logic [2:0]  dvfs_active_i
);
  logic        ack, err, irq, idle_req, cg_en, iso_en, cpu_rst_n, pwr_sw_en, ram_ret;
  logic [31:0] rdata;
  logic [1:0]  dvfs_sel, vsel;
  logic [4:0]  state;

  pmu #(
    .NUM_OP (3), .RESET_OP (2'd2), .VSETTLE_CYCLES (2), .RET_CYCLES (1),
    .ISO_CYCLES (1), .RST_CLK_CYCLES (2)
  ) dut (
    .clk_i, .rst_ni, .req_i, .we_i, .addr_i, .wdata_i, .wstrb_i,
    .ack_o (ack), .rdata_o (rdata), .err_o (err),
    .meip_i, .mtip_i, .msip_i,
    .core_sleep_i, .idle_ack_i, .cache_clean_i, .idle_req_o (idle_req),
    .cg_en_o (cg_en), .cg_ack_i, .bus_idle_i,
    .iso_en_o (iso_en), .cpu_rst_no (cpu_rst_n), .cpu_rst_ack_i, .pwr_sw_en_o (pwr_sw_en),
    .pwr_good_i, .ram_ret_o (ram_ret),
    .dvfs_sel_o (dvfs_sel), .dvfs_active_i, .vsel_o (vsel),
    .irq_o (irq), .state_o (state)
  );

  // ---------------- reset ----------------
  logic init = 1'b1;
  always @(posedge clk_i) init <= 1'b0;
  always @(*) if (init) assume (!rst_ni);
  always @(posedge clk_i) if (!init && $past(rst_ni)) assume (rst_ni);

  // ---------------- environment ----------------
  // Values while the PMU is in reset match the power-on state.
  always @(*) if (!rst_ni) assume (pwr_good_i && cg_ack_i && !idle_ack_i);

  always @(posedge clk_i) if (!init) begin
    // Power switch acknowledge only moves towards the switch control.
    if (pwr_good_i != $past(pwr_good_i)) assume (pwr_good_i == $past(pwr_sw_en));
    // Clock-gate acknowledge (synchronized enable) follows the request.
    if (cg_ack_i != $past(cg_ack_i)) assume (cg_ack_i == $past(cg_en));
    // Reset status follows the reset request.
    if (cpu_rst_ack_i != $past(cpu_rst_ack_i)) assume (cpu_rst_ack_i == $past(cpu_rst_n));
    // The core acknowledges only a pending request of a non-isolated core,
    // and withdraws the ack only after the request is withdrawn (or when it
    // is isolated: the isolation cell clamps the ack to 0).
    if (idle_ack_i && !$past(idle_ack_i)) assume ($past(idle_req) && !$past(iso_en));
    if (!idle_ack_i && $past(idle_ack_i)) assume (!$past(idle_req) || $past(iso_en));
  end
  // Isolated outputs read as 0; a core held in reset neither sleeps nor acks.
  always @(*) if (iso_en) assume (!idle_ack_i);
  always @(*) if (!cpu_rst_ack_i) assume (!idle_ack_i && !core_sleep_i);
  // ---------------- helper invariants (proven, strengthen induction) ------
  localparam logic [4:0] RUN = 0, IDLE_REQ = 1, CLK_GATE = 2, IDLE = 3, VUP = 4, SWITCH = 5,
    VDN = 6, DRAIN = 7, ISO_ON = 8, PWR_OFF = 9, OFF = 10, RET_EXIT = 11, PWR_ON = 12,
    RST_CLK_ON = 13, RST_CLK_OFF = 14, RST_REL = 15, ISO_OFF = 16, UNGATE = 17, WAKE_REL = 18;

  always @(posedge clk_i) if (rst_ni) begin
    // clock gate acknowledged off in every state after CLK_GATE
    if (state == IDLE || state == VUP || state == SWITCH || state == VDN || state == DRAIN ||
        state == ISO_ON || state == PWR_OFF || state == OFF || state == RET_EXIT ||
        state == PWR_ON || state == RST_REL || state == ISO_OFF)
      h_cg_off: assert (!cg_ack_i);
    if (state == RUN || state == IDLE_REQ || state == WAKE_REL)
      h_cg_on: assert (cg_ack_i);
    // power switch acknowledge
    if (state == OFF || state == RET_EXIT) h_pg_off: assert (!pwr_good_i);
    if (state == RUN || state == IDLE_REQ || state == CLK_GATE || state == IDLE || state == VUP ||
        state == SWITCH || state == VDN || state == DRAIN || state == ISO_ON ||
        state == RST_CLK_ON || state == RST_CLK_OFF || state == RST_REL || state == ISO_OFF ||
        state == UNGATE || state == WAKE_REL)
      h_pg_on: assert (pwr_good_i);
    // CPU reset status
    // (RUN excluded: after power-on the CPU reset may still be releasing)
    if (state == IDLE_REQ || state == CLK_GATE || state == IDLE || state == VUP ||
        state == SWITCH || state == VDN || state == DRAIN || state == ISO_OFF || state == UNGATE ||
        state == WAKE_REL)
      h_rst_rel: assert (cpu_rst_ack_i);
    if (state == PWR_OFF || state == OFF || state == RET_EXIT || state == PWR_ON ||
        state == RST_CLK_ON || state == RST_CLK_OFF)
      h_rst_on: assert (!cpu_rst_ack_i);
    // core handshake
    if (state == RUN) h_ack_off: assert (!idle_ack_i);
    if (state == CLK_GATE || state == IDLE || state == VUP || state == SWITCH || state == VDN ||
        state == DRAIN)
      h_ack_on: assert (idle_ack_i);
  end
endmodule
