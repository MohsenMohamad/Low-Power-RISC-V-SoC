// -----------------------------------------------------------------------------
// pmu - power management unit (PD_AON, clk_aon)
//
// Controls PD_CPU: clock gate, isolation, reset, power switch, RAM retention
// and the DVFS operating point (clock mux select + regulator voltage select).
// All inputs coming from other clock domains arrive already synchronized.
//
// CPU power states
//   RUN         clock running
//   IDLE        WFI, clk_cpu gated, domain powered          (CTRL.MODE = 0)
//   SLEEP       WFI, domain switched off                    (CTRL.MODE = 1)
//   DEEP_SLEEP  SLEEP + main RAM in retention mode          (CTRL.MODE = 2)
//
// Entry (WFI seen and CTRL.LP_EN = 1):
//   RUN -> IDLE_REQ (idle_req/idle_ack handshake with the core)
//       -> CLK_GATE (gate clk_cpu, wait for gate acknowledge)
//       -> IDLE                                   (MODE = IDLE)
//       -> BUS_DRAIN -> ISO_ON -> PWR_OFF -> OFF  (MODE = SLEEP/DEEP_SLEEP)
//   DEEP_SLEEP additionally asserts ram_ret_o on the way into OFF.
// Wake (any of meip/mtip/msip):
//   OFF -> [RET_EXIT] -> PWR_ON (switch on, wait power_good)
//       -> RST_CLK_ON -> RST_CLK_OFF (reset-clocking window for synchronous-
//          reset logic; RST_CLK_CYCLES = 0 skips the clock pulse train)
//       -> RST_REL (reset release) -> ISO_OFF -> CLK_UNGATE -> WAKE_REL -> RUN
//   IDLE -> CLK_UNGATE -> WAKE_REL -> RUN
// DVFS: a new target written to DVFS is applied the next time the PMU is in
// IDLE (clock gated): DVFS_VUP (raise voltage first if going faster),
// DVFS_SWITCH (glitch-free clock mux), DVFS_VDN (lower voltage after going
// slower), then back to IDLE and DVFS_DONE is raised (interrupt source).
// Safety aborts: IDLE_REQ -> WAKE_REL if the core left WFI before
// acknowledging; BUS_DRAIN -> IDLE (STATUS.ERR_DIRTY, the power-down is
// refused and the core stays clock gated until the wake event) unless the
// core reports both idle_ack and cache_clean (no dirty D-cache line) at
// power-down (doc/SPEC.md: PD_CPU is powered down only while idle_ack and
// cache_clean are both asserted).
//
// Register map (offsets):
//   0x00 CTRL       RW  [1:0] MODE, [8] LP_EN
//   0x04 STATUS     [4:0] STATE (RO), [9:8] CUR_OP (RO), [10] DVFS_PEND (RO),
//                   [16] RESUME, [17] RESUME_DEEP, [18] DVFS_DONE,
//                   [19] ERR_DIRTY (W1C)
//   0x08 DVFS       RW  [1:0] TARGET_OP
//   0x0C IRQ_EN     RW  [0] DVFS_DONE interrupt enable
//   0x10 SCRATCH0   RW  retained scratch (resume context pointer)
//   0x14 SCRATCH1   RW  retained scratch (resume magic)
//   0x18 WAKE_CAUSE RO  [0] meip [1] mtip [2] msip sampled at the last wake
//   0x1C SLEEP_CNT  RO  number of completed power-off cycles
//   0x20 VSEL       RO  [1:0] current regulator voltage select
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module pmu #(
  parameter int          NUM_OP         = 3,
  parameter logic [1:0]  RESET_OP       = 2'd2,
  parameter int          VSETTLE_CYCLES = 8,   // regulator settling time
  parameter int          RET_CYCLES     = 4,   // RAM retention exit time
  parameter int          ISO_CYCLES     = 2,   // isolation/reset settle time
  parameter int          RST_CLK_CYCLES = 4    // clocks with reset asserted
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // register interface
  input  logic        req_i,
  input  logic        we_i,
  input  logic [11:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic [3:0]  wstrb_i,
  output logic        ack_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  // wake events (PD_AON, clk_aon)
  input  logic        meip_i,
  input  logic        mtip_i,
  input  logic        msip_i,

  // core handshake (synchronized from clk_cpu, isolated)
  input  logic        core_sleep_i,   // core is in WFI
  input  logic        idle_ack_i,     // core acknowledged idle_req
  input  logic        cache_clean_i,  // no dirty lines in the D-cache
  output logic        idle_req_o,

  // clock gate (cg_en_o is synchronized into clk_cpu_root; cg_ack_i back)
  output logic        cg_en_o,
  input  logic        cg_ack_i,

  // bus
  input  logic        bus_idle_i,

  // power control
  output logic        iso_en_o,
  output logic        cpu_rst_no,     // reset request (async assert)
  input  logic        cpu_rst_ack_i,  // synchronized: 1 = reset released
  output logic        pwr_sw_en_o,
  input  logic        pwr_good_i,
  output logic        ram_ret_o,

  // DVFS
  output logic [1:0]        dvfs_sel_o,
  input  logic [NUM_OP-1:0] dvfs_active_i, // synchronized one-hot mux status
  output logic [1:0]        vsel_o,

  output logic        irq_o,
  output logic [4:0]  state_o
);
  // ---------------------------------------------------------------------------
  // State encoding (exported for coverage / debug)
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ST_RUN         = 5'd0,
    ST_IDLE_REQ    = 5'd1,
    ST_CLK_GATE    = 5'd2,
    ST_IDLE        = 5'd3,
    ST_DVFS_VUP    = 5'd4,
    ST_DVFS_SWITCH = 5'd5,
    ST_DVFS_VDN    = 5'd6,
    ST_BUS_DRAIN   = 5'd7,
    ST_ISO_ON      = 5'd8,
    ST_PWR_OFF     = 5'd9,
    ST_OFF         = 5'd10,
    ST_RET_EXIT    = 5'd11,
    ST_PWR_ON      = 5'd12,
    ST_RST_CLK_ON  = 5'd13,
    ST_RST_CLK_OFF = 5'd14,
    ST_RST_REL     = 5'd15,
    ST_ISO_OFF     = 5'd16,
    ST_CLK_UNGATE  = 5'd17,
    ST_WAKE_REL    = 5'd18
  } state_e;

  localparam logic [1:0] MODE_IDLE  = 2'd0;
  // MODE_SLEEP = 2'd1 (any mode other than IDLE/DEEP powers down without retention)
  localparam logic [1:0] MODE_DEEP  = 2'd2;

  state_e      state_q, state_d;
  logic [15:0] cnt_q;
  logic        cnt_clr;

  // registers
  logic [1:0]  mode_q, mode_lat_q;
  logic        lp_en_q;
  logic [1:0]  target_op_q;
  logic [1:0]  cur_op_q;
  logic [1:0]  vsel_q;
  logic        dvfs_pend;
  logic [1:0]  seq_op_q;     // target latched for the running DVFS sequence
  logic        irq_en_q;
  logic        st_resume_q, st_resume_deep_q, st_dvfs_done_q, st_err_dirty_q;
  logic [31:0] scratch0_q, scratch1_q;
  logic [2:0]  wake_cause_q;
  logic [31:0] sleep_cnt_q;

  logic wake;
  logic vwait_q;   // a voltage change is settling in DVFS_VUP / DVFS_VDN
  assign wake = meip_i | mtip_i | msip_i;

  // ---------------------------------------------------------------------------
  // Next-state logic
  // ---------------------------------------------------------------------------
  // A DVFS change is pending whenever the requested and current points
  // differ. The sequence works on seq_op_q (latched when it starts), so a
  // DVFS register write while a sequence runs cannot break the
  // voltage-before-frequency ordering; it simply triggers another sequence.
  assign dvfs_pend = (target_op_q != cur_op_q);

  // Voltage needed while switching: the higher of the current and new point.
  logic [1:0] vup_level;
  assign vup_level = (target_op_q > cur_op_q) ? target_op_q : cur_op_q;

  logic [NUM_OP-1:0] seq_onehot;
  assign seq_onehot = NUM_OP'(1) << seq_op_q;

  always_comb begin
    state_d = state_q;
    cnt_clr = 1'b0;
    unique case (state_q)
      ST_RUN:
        if (lp_en_q && core_sleep_i) state_d = ST_IDLE_REQ;
      ST_IDLE_REQ:
        if (idle_ack_i)         state_d = ST_CLK_GATE;
        else if (!core_sleep_i) state_d = ST_WAKE_REL;      // core left WFI
      ST_CLK_GATE:
        if (!cg_ack_i) begin
          if (mode_lat_q == MODE_IDLE) state_d = ST_IDLE;
          else                         state_d = ST_BUS_DRAIN;
        end
      ST_IDLE:
        if (dvfs_pend) state_d = ST_DVFS_VUP;
        else if (wake)   state_d = ST_CLK_UNGATE;
      ST_DVFS_VUP:
        if (!vwait_q || cnt_q >= 16'(VSETTLE_CYCLES)) state_d = ST_DVFS_SWITCH;
      ST_DVFS_SWITCH:
        if (dvfs_active_i == seq_onehot) state_d = ST_DVFS_VDN;
      ST_DVFS_VDN:
        if (!vwait_q || cnt_q >= 16'(VSETTLE_CYCLES)) state_d = ST_IDLE;
      ST_BUS_DRAIN:
        if (!cache_clean_i || !idle_ack_i) state_d = ST_IDLE;   // refuse power-down: stay clock gated
        else if (bus_idle_i) state_d = ST_ISO_ON;
      ST_ISO_ON:
        if (cnt_q >= 16'(ISO_CYCLES) && !cpu_rst_ack_i) state_d = ST_PWR_OFF;
      ST_PWR_OFF:
        if (!pwr_good_i) state_d = ST_OFF;
      ST_OFF:
        if (wake) begin
          if (ram_ret_o) state_d = ST_RET_EXIT;
          else           state_d = ST_PWR_ON;
        end
      ST_RET_EXIT:
        if (cnt_q >= 16'(RET_CYCLES)) state_d = ST_PWR_ON;
      ST_PWR_ON:
        if (pwr_good_i) begin
          if (RST_CLK_CYCLES > 0) state_d = ST_RST_CLK_ON;
          else                    state_d = ST_RST_REL;
        end
      ST_RST_CLK_ON:
        if (cg_ack_i && cnt_q >= 16'(RST_CLK_CYCLES)) state_d = ST_RST_CLK_OFF;
      ST_RST_CLK_OFF:
        if (!cg_ack_i) state_d = ST_RST_REL;
      ST_RST_REL:
        if (cpu_rst_ack_i) state_d = ST_ISO_OFF;
      ST_ISO_OFF:
        if (cnt_q >= 16'(ISO_CYCLES)) state_d = ST_CLK_UNGATE;
      ST_CLK_UNGATE:
        if (cg_ack_i) state_d = ST_WAKE_REL;
      ST_WAKE_REL:
        if (!idle_ack_i) state_d = ST_RUN;
      default: state_d = ST_RUN;
    endcase
    if (state_d != state_q) cnt_clr = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Outputs, registered (all control outputs are glitch-free flop outputs)
  // ---------------------------------------------------------------------------
  logic idle_req_q, cg_en_q, iso_en_q, cpu_rst_n_q, pwr_sw_en_q, ram_ret_q;
  logic [1:0] dvfs_sel_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_RUN;
      cnt_q       <= '0;
      idle_req_q  <= 1'b0;
      cg_en_q     <= 1'b1;
      iso_en_q    <= 1'b0;
      cpu_rst_n_q <= 1'b1;
      pwr_sw_en_q <= 1'b1;
      ram_ret_q   <= 1'b0;
      dvfs_sel_q  <= RESET_OP;
      vsel_q      <= RESET_OP;
      cur_op_q    <= RESET_OP;
      mode_lat_q  <= MODE_IDLE;
      vwait_q     <= 1'b0;
      seq_op_q    <= RESET_OP;
    end else begin
      state_q <= state_d;
      cnt_q   <= cnt_clr ? 16'd0 : ((cnt_q == 16'hFFFF) ? cnt_q : cnt_q + 16'd1);

      unique case (state_d)
        ST_IDLE_REQ: begin
          idle_req_q <= 1'b1;
          if (state_q == ST_RUN) mode_lat_q <= mode_q;
        end
        ST_CLK_GATE:    cg_en_q <= 1'b0;
        ST_DVFS_VUP: if (state_q != ST_DVFS_VUP) begin
          vsel_q   <= vup_level;
          vwait_q  <= (vup_level != vsel_q);
          seq_op_q <= target_op_q;
        end
        ST_DVFS_SWITCH: dvfs_sel_q <= seq_op_q;
        ST_DVFS_VDN: if (state_q != ST_DVFS_VDN) begin
          vsel_q   <= seq_op_q;
          cur_op_q <= seq_op_q;
          vwait_q  <= (seq_op_q != vsel_q);
        end
        ST_ISO_ON: begin
          iso_en_q    <= 1'b1;
          cpu_rst_n_q <= 1'b0;
        end
        ST_PWR_OFF: begin
          pwr_sw_en_q <= 1'b0;
          idle_req_q  <= 1'b0;
        end
        ST_OFF:         ram_ret_q <= (mode_lat_q == MODE_DEEP);
        ST_RET_EXIT:    ram_ret_q <= 1'b0;
        ST_PWR_ON:      pwr_sw_en_q <= 1'b1;
        ST_RST_CLK_ON:  cg_en_q <= 1'b1;
        ST_RST_CLK_OFF: cg_en_q <= 1'b0;
        ST_RST_REL:     cpu_rst_n_q <= 1'b1;
        ST_ISO_OFF:     iso_en_q <= 1'b0;
        ST_CLK_UNGATE:  cg_en_q <= 1'b1;
        ST_WAKE_REL:    idle_req_q <= 1'b0;
        default: ;
      endcase
    end
  end

  assign idle_req_o  = idle_req_q;
  assign cg_en_o     = cg_en_q;
  assign iso_en_o    = iso_en_q;
  assign cpu_rst_no  = cpu_rst_n_q;
  assign pwr_sw_en_o = pwr_sw_en_q;
  assign ram_ret_o   = ram_ret_q;
  assign dvfs_sel_o  = dvfs_sel_q;
  assign vsel_o      = vsel_q;
  assign state_o     = state_q;

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  logic wr;
  assign wr    = req_i && we_i;
  assign ack_o = req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mode_q           <= MODE_IDLE;
      lp_en_q          <= 1'b1;
      target_op_q      <= RESET_OP;
      irq_en_q         <= 1'b0;
      st_resume_q      <= 1'b0;
      st_resume_deep_q <= 1'b0;
      st_dvfs_done_q   <= 1'b0;
      st_err_dirty_q   <= 1'b0;
      scratch0_q       <= '0;
      scratch1_q       <= '0;
      wake_cause_q     <= '0;
      sleep_cnt_q      <= '0;
    end else begin
      // hardware events
      if (state_q == ST_DVFS_VDN && state_d == ST_IDLE) begin
        st_dvfs_done_q <= 1'b1;
      end
      if ((state_q == ST_IDLE && state_d == ST_CLK_UNGATE) ||
          (state_q == ST_OFF  && state_d != ST_OFF))
        wake_cause_q <= {msip_i, mtip_i, meip_i};
      if (state_q == ST_BUS_DRAIN && state_d == ST_IDLE) st_err_dirty_q <= 1'b1;
      if (state_q == ST_PWR_OFF && state_d == ST_OFF) sleep_cnt_q <= sleep_cnt_q + 32'd1;
      if (state_q == ST_RST_REL && state_d == ST_ISO_OFF) begin
        st_resume_q      <= 1'b1;
        st_resume_deep_q <= (mode_lat_q == MODE_DEEP);
      end

      // software writes (full-word writes only)
      if (wr && wstrb_i == 4'hF) begin
        case (addr_i[11:2])
          10'h0: begin
            mode_q  <= (wdata_i[1:0] == 2'd3) ? MODE_IDLE : wdata_i[1:0];
            lp_en_q <= wdata_i[8];
          end
          10'h1: begin
            if (wdata_i[16]) st_resume_q      <= 1'b0;
            if (wdata_i[17]) st_resume_deep_q <= 1'b0;
            if (wdata_i[18]) st_dvfs_done_q   <= 1'b0;
            if (wdata_i[19]) st_err_dirty_q   <= 1'b0;
          end
          10'h2: begin
            if (wdata_i[1:0] < 2'(NUM_OP)) begin
              target_op_q <= wdata_i[1:0];
            end
          end
          10'h3: irq_en_q   <= wdata_i[0];
          10'h4: scratch0_q <= wdata_i;
          10'h5: scratch1_q <= wdata_i;
          default: ;
        endcase
      end
    end
  end

  assign irq_o = st_dvfs_done_q & irq_en_q;

  logic unused;
  assign unused = ^addr_i[1:0];

  always_comb begin
    rdata_o = '0;
    err_o   = we_i && (wstrb_i != 4'hF);
    case (addr_i[11:2])
      10'h0: rdata_o = {23'b0, lp_en_q, 6'b0, mode_q};
      10'h1: rdata_o = {12'b0, st_err_dirty_q, st_dvfs_done_q, st_resume_deep_q, st_resume_q,
                        5'b0, dvfs_pend, cur_op_q, 3'b0, state_q};
      10'h2: rdata_o = {30'b0, target_op_q};
      10'h3: rdata_o = {31'b0, irq_en_q};
      10'h4: rdata_o = scratch0_q;
      10'h5: rdata_o = scratch1_q;
      10'h6: begin rdata_o = {29'b0, wake_cause_q}; err_o = we_i; end
      10'h7: begin rdata_o = sleep_cnt_q;           err_o = we_i; end
      10'h8: begin rdata_o = {30'b0, vsel_q};       err_o = we_i; end
      default: err_o = 1'b1;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Assertions (sequencing and isolation). Also proven with SymbiYosys.
  // ---------------------------------------------------------------------------
  // Legal state encoding.
  `SVA_ASSERT(a_state_legal, clk_i, rst_ni, state_q <= ST_WAKE_REL)
  // Domain not fully powered => outputs isolated.
  `SVA_ASSERT_IMP(a_iso_when_unpowered, clk_i, rst_ni, !pwr_sw_en_q || !pwr_good_i, iso_en_q)
  // Switch is only off while isolated and held in reset.
  `SVA_ASSERT_IMP(a_off_needs_iso_rst, clk_i, rst_ni, !pwr_sw_en_q, iso_en_q && !cpu_rst_n_q)
  // Isolation is only released with the reset released and power good.
  `SVA_ASSERT_IMP(a_iso_off_needs_power, clk_i, rst_ni, !iso_en_q, pwr_sw_en_q && cpu_rst_n_q)
  // The clock is gated whenever isolation changes.
  `SVA_ASSERT_IMP(a_iso_change_clk_gated, clk_i, rst_ni,
                  iso_en_q != $past(iso_en_q), !cg_en_q && !$past(cg_en_q))
  // The clock only runs while isolated if the core is held in reset.
  `SVA_ASSERT_IMP(a_clk_iso_only_in_reset, clk_i, rst_ni, cg_en_q && iso_en_q, !cpu_rst_n_q && pwr_sw_en_q)
  // Isolation (and with it the power-down) is only applied once the bus is
  // idle (no transaction can be cut), the core acknowledged idle and the
  // D-cache holds no dirty line.
  `SVA_ASSERT_IMP(a_iso_on_bus_idle, clk_i, rst_ni,
                  iso_en_q && !$past(iso_en_q),
                  $past(bus_idle_i) && $past(cache_clean_i) && $past(idle_ack_i))
  // The switch only turns off with the clock gated and the core in reset.
  `SVA_ASSERT_IMP(a_pwr_off_gated, clk_i, rst_ni,
                  !pwr_sw_en_q && $past(pwr_sw_en_q), !cg_en_q && !$past(cpu_rst_ack_i))
  // RAM retention only while the CPU domain is off (nothing can access RAM).
  `SVA_ASSERT_IMP(a_ret_only_cpu_off, clk_i, rst_ni, ram_ret_q, !pwr_sw_en_q && iso_en_q)
  // The DVFS mux select only changes with the CPU clock gated.
  `SVA_ASSERT_IMP(a_dvfs_switch_gated, clk_i, rst_ni,
                  dvfs_sel_q != $past(dvfs_sel_q), !cg_en_q && !$past(cg_ack_i))
  // Voltage is always high enough for the selected clock (and the old one).
  `SVA_ASSERT(a_vsel_sufficient, clk_i, rst_ni, vsel_q >= dvfs_sel_q && vsel_q >= cur_op_q)
  // The clock of a running (not reset) core is only gated after the
  // idle_req/idle_ack handshake has completed.
  `SVA_ASSERT_IMP(a_gate_needs_handshake, clk_i, rst_ni,
                  !cg_en_q && $past(cg_en_q),
                  ($past(idle_req_q) && $past(idle_ack_i)) || !$past(cpu_rst_n_q))
  // idle_req stays asserted while a powered, running core is clock gated.
  `SVA_ASSERT_IMP(a_gated_keeps_idle_req, clk_i, rst_ni,
                  !cg_en_q && pwr_sw_en_q && !iso_en_q && cpu_rst_n_q && state_q != ST_ISO_OFF,
                  idle_req_q)
  // Leaving the domain powered and unisolated implies RUN-type states.
  `SVA_ASSERT_IMP(a_run_clk_on, clk_i, rst_ni, state_q == ST_RUN, cg_en_q && !iso_en_q && pwr_sw_en_q)

  // Per-state control outputs {sw_en, iso_en, rst_n, cg_en, ret} (the full
  // sequencing contract; also the inductive invariant for the formal proof).
`ifdef SVA_ON
  `define PMU_CTL_USED
`elsif FORMAL
  `define PMU_CTL_USED
`endif
`ifdef PMU_CTL_USED
  logic [4:0] ctl;
  assign ctl = {pwr_sw_en_q, iso_en_q, cpu_rst_n_q, cg_en_q, ram_ret_q};
`endif
  `SVA_ASSERT_IMP(a_ctl_run,      clk_i, rst_ni, state_q == ST_RUN || state_q == ST_IDLE_REQ ||
                                  state_q == ST_CLK_UNGATE || state_q == ST_WAKE_REL, ctl == 5'b10110)
  `SVA_ASSERT_IMP(a_ctl_gated,    clk_i, rst_ni, (state_q == ST_CLK_GATE || state_q == ST_IDLE || state_q == ST_DVFS_VUP || state_q == ST_DVFS_SWITCH || state_q == ST_DVFS_VDN || state_q == ST_BUS_DRAIN || state_q == ST_ISO_OFF), ctl == 5'b10100)
  `SVA_ASSERT_IMP(a_ctl_iso,      clk_i, rst_ni, state_q == ST_ISO_ON || state_q == ST_PWR_ON ||
                                  state_q == ST_RST_CLK_OFF, ctl == 5'b11000)
  `SVA_ASSERT_IMP(a_ctl_off,      clk_i, rst_ni, state_q == ST_PWR_OFF || state_q == ST_RET_EXIT,
                                  ctl == 5'b01000)
  `SVA_ASSERT_IMP(a_ctl_off_ret,  clk_i, rst_ni, state_q == ST_OFF,
                                  ctl == {4'b0100, mode_lat_q == MODE_DEEP})
  `SVA_ASSERT_IMP(a_ctl_rstclk,   clk_i, rst_ni, state_q == ST_RST_CLK_ON, ctl == 5'b11010)
  `SVA_ASSERT_IMP(a_ctl_rstrel,   clk_i, rst_ni, state_q == ST_RST_REL, ctl == 5'b11100)
  `SVA_ASSERT_IMP(a_req_idle,     clk_i, rst_ni, (state_q == ST_IDLE_REQ || state_q == ST_CLK_GATE || state_q == ST_IDLE || state_q == ST_DVFS_VUP || state_q == ST_DVFS_SWITCH || state_q == ST_DVFS_VDN || state_q == ST_BUS_DRAIN || state_q == ST_ISO_ON),
                                  idle_req_q)
  `SVA_ASSERT_IMP(a_req_off,      clk_i, rst_ni, (state_q == ST_RUN || state_q == ST_PWR_OFF || state_q == ST_OFF || state_q == ST_RET_EXIT || state_q == ST_PWR_ON || state_q == ST_RST_CLK_ON || state_q == ST_RST_CLK_OFF || state_q == ST_RST_REL || state_q == ST_ISO_OFF || state_q == ST_WAKE_REL), !idle_req_q)
  // DVFS bookkeeping: outside a sequence the mux and regulator sit at cur_op.
  `SVA_ASSERT(a_op_range,         clk_i, rst_ni, cur_op_q < 2'(NUM_OP) && seq_op_q < 2'(NUM_OP) &&
                                  target_op_q < 2'(NUM_OP) && vsel_q < 2'(NUM_OP))
  `SVA_ASSERT_IMP(a_dvfs_idle,    clk_i, rst_ni, !(state_q == ST_DVFS_VUP || state_q == ST_DVFS_SWITCH || state_q == ST_DVFS_VDN),
                                  dvfs_sel_q == cur_op_q && vsel_q == cur_op_q)
  `SVA_ASSERT_IMP(a_dvfs_vup,     clk_i, rst_ni, state_q == ST_DVFS_VUP,
                                  dvfs_sel_q == cur_op_q && vsel_q >= seq_op_q && vsel_q >= cur_op_q)
  `SVA_ASSERT_IMP(a_dvfs_switch,  clk_i, rst_ni, state_q == ST_DVFS_SWITCH,
                                  dvfs_sel_q == seq_op_q && vsel_q >= seq_op_q && vsel_q >= cur_op_q)
  `SVA_ASSERT_IMP(a_dvfs_vdn,     clk_i, rst_ni, state_q == ST_DVFS_VDN,
                                  dvfs_sel_q == seq_op_q && cur_op_q == seq_op_q && vsel_q == seq_op_q)

  // Transition coverage (every FSM arc).
  `SVA_COVER(c_run_idlereq,      clk_i, rst_ni, state_q == ST_RUN         && state_d == ST_IDLE_REQ)
  `SVA_COVER(c_idlereq_clkgate,  clk_i, rst_ni, state_q == ST_IDLE_REQ    && state_d == ST_CLK_GATE)
  `SVA_COVER(c_idlereq_abort,    clk_i, rst_ni, state_q == ST_IDLE_REQ    && state_d == ST_WAKE_REL)
  `SVA_COVER(c_clkgate_idle,     clk_i, rst_ni, state_q == ST_CLK_GATE    && state_d == ST_IDLE)
  `SVA_COVER(c_clkgate_drain,    clk_i, rst_ni, state_q == ST_CLK_GATE    && state_d == ST_BUS_DRAIN)
  `SVA_COVER(c_idle_dvfs,        clk_i, rst_ni, state_q == ST_IDLE        && state_d == ST_DVFS_VUP)
  `SVA_COVER(c_idle_wake,        clk_i, rst_ni, state_q == ST_IDLE        && state_d == ST_CLK_UNGATE)
  `SVA_COVER(c_vup_switch,       clk_i, rst_ni, state_q == ST_DVFS_VUP    && state_d == ST_DVFS_SWITCH)
  `SVA_COVER(c_switch_vdn,       clk_i, rst_ni, state_q == ST_DVFS_SWITCH && state_d == ST_DVFS_VDN)
  `SVA_COVER(c_vdn_idle,         clk_i, rst_ni, state_q == ST_DVFS_VDN    && state_d == ST_IDLE)
  `SVA_COVER(c_drain_iso,        clk_i, rst_ni, state_q == ST_BUS_DRAIN   && state_d == ST_ISO_ON)
  `SVA_COVER(c_drain_dirty,      clk_i, rst_ni, state_q == ST_BUS_DRAIN   && state_d == ST_IDLE)
  `SVA_COVER(c_iso_pwroff,       clk_i, rst_ni, state_q == ST_ISO_ON      && state_d == ST_PWR_OFF)
  `SVA_COVER(c_pwroff_off,       clk_i, rst_ni, state_q == ST_PWR_OFF     && state_d == ST_OFF)
  `SVA_COVER(c_off_ret_exit,     clk_i, rst_ni, state_q == ST_OFF         && state_d == ST_RET_EXIT)
  `SVA_COVER(c_off_pwron,        clk_i, rst_ni, state_q == ST_OFF         && state_d == ST_PWR_ON)
  `SVA_COVER(c_ret_exit_pwron,   clk_i, rst_ni, state_q == ST_RET_EXIT    && state_d == ST_PWR_ON)
  `SVA_COVER(c_pwron_rstclk,     clk_i, rst_ni, state_q == ST_PWR_ON      && state_d == ST_RST_CLK_ON)
  `SVA_COVER(c_rstclk_on_off,    clk_i, rst_ni, state_q == ST_RST_CLK_ON  && state_d == ST_RST_CLK_OFF)
  `SVA_COVER(c_rstclk_off_rel,   clk_i, rst_ni, state_q == ST_RST_CLK_OFF && state_d == ST_RST_REL)
  `SVA_COVER(c_rstrel_isooff,    clk_i, rst_ni, state_q == ST_RST_REL     && state_d == ST_ISO_OFF)
  `SVA_COVER(c_isooff_ungate,    clk_i, rst_ni, state_q == ST_ISO_OFF     && state_d == ST_CLK_UNGATE)
  `SVA_COVER(c_ungate_wakerel,   clk_i, rst_ni, state_q == ST_CLK_UNGATE  && state_d == ST_WAKE_REL)
  `SVA_COVER(c_wakerel_run,      clk_i, rst_ni, state_q == ST_WAKE_REL    && state_d == ST_RUN)
endmodule
