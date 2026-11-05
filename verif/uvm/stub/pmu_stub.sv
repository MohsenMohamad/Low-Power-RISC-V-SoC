// -----------------------------------------------------------------------------
// pmu_stub.sv
//
// Minimal, synthesizable stand-in for the PD_AON Power Management Unit, used
// only as a verification vehicle for the UVM environment in verif/uvm/ while the
// real PMU RTL (rtl/) is developed on another branch.
//
// It implements the PMU behaviour from doc/SPEC.md at subsystem level:
//   * AXI4-Lite slave (32-bit address/data, one outstanding read and write).
//   * PD_CPU power sequencing:
//       power-down : clock gate -> isolation on -> reset assert
//                    -> [retention on, DEEP_SLEEP only] -> switch off
//       wake-up    : switch on -> wait power_good -> [retention off]
//                    -> reset release -> isolation off -> clock on
//   * CPU power states RUN / IDLE (clock gated on WFI) / SLEEP / DEEP_SLEEP.
//   * DVFS: 3 operating points, the clock-mux select only changes in IDLE.
//   * Isolation clamps on every PD_CPU -> PD_AON signal.
//   * A small register window that lives in PD_CPU; any access while PD_CPU is
//     not fully up (not RUN) returns SLVERR.
//
// SPEC.md does not define a PMU register map, so this stub defines one
// (documented in verif/uvm/README.md and mirrored by verif/uvm/ral/).
//
// Everything runs on clk_aon. The stub is NOT the deliverable PMU: it has no
// CDC logic because the testbench drives all PMU inputs synchronously.
//
// BUG_MODE (checker self-test only, 0 = correct behaviour):
//   1 : isolation is enabled before the clock is gated (sequencing order bug)
//   2 : PD_CPU window returns OKAY instead of SLVERR while powered off
//   3 : isolation clamp value is wrong (passes PD_CPU outputs through)
// -----------------------------------------------------------------------------
module pmu_stub #(
  parameter int unsigned IRQ_W       = 8,
  parameter int unsigned ISO_W       = 16,
  parameter logic [ISO_W-1:0] ISO_CLAMP = 16'h00F0,
  parameter logic [31:0] ID_VALUE    = 32'h504D_5501,
  parameter int unsigned BUG_MODE    = 0
) (
  input  logic              clk_aon,
  input  logic              rst_aon_n,

  // ---------------- AXI4-Lite slave ----------------
  input  logic [31:0]       s_axi_awaddr,
  input  logic [2:0]        s_axi_awprot,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [31:0]       s_axi_araddr,
  input  logic [2:0]        s_axi_arprot,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,

  // ---------------- PD_CPU power control ----------------
  output logic              cpu_clk_en_o,    // 1 = clk_cpu running (clock gate open)
  output logic              cpu_iso_en_o,    // 1 = isolation clamps active
  output logic              cpu_ret_en_o,    // 1 = RAM retention mode
  output logic              cpu_pwr_en_o,    // 1 = power switch closed
  input  logic              cpu_pwr_good_i,  // power switch: supply is good
  output logic              cpu_rst_n_o,     // PD_CPU reset, active low
  output logic [1:0]        dvfs_sel_o,      // glitch-free clock mux select

  // ---------------- PD_CPU <-> PD_AON signals ----------------
  input  logic              cpu_wfi_i,       // CPU is in WFI
  input  logic [IRQ_W-1:0]  wake_irq_i,      // wake sources (level)
  input  logic [ISO_W-1:0]  pd_cpu_out_i,    // raw PD_CPU outputs
  output logic [ISO_W-1:0]  pd_cpu_out_iso_o // isolated outputs seen by PD_AON
);

  // ---------------------------------------------------------------------------
  // Register map (byte offsets)
  // ---------------------------------------------------------------------------
  localparam logic [11:0] A_ID        = 12'h000;
  localparam logic [11:0] A_CTRL      = 12'h004;
  localparam logic [11:0] A_STATUS    = 12'h008;
  localparam logic [11:0] A_DVFS      = 12'h00C;
  localparam logic [11:0] A_WAKE_MASK = 12'h010;
  localparam logic [11:0] A_WAKE_CAUSE= 12'h014;
  localparam logic [11:0] A_SEQ_DELAY = 12'h018;
  localparam logic [11:0] A_PD_COUNT  = 12'h01C;
  localparam logic [11:0] A_CPU_WIN   = 12'h100;   // 0x100..0x10C, PD_CPU

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // STATUS.STATE encoding
  typedef enum logic [2:0] {
    ST_RUN   = 3'd0,
    ST_IDLE  = 3'd1,
    ST_SLEEP = 3'd2,
    ST_DEEP  = 3'd3,
    ST_PD    = 3'd4,   // power-down sequence in progress
    ST_PU    = 3'd5    // power-up sequence in progress
  } state_e;

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic             ctrl_pd_en, ctrl_ret_en;
  logic [1:0]       dvfs_tgt;
  logic [IRQ_W-1:0] wake_mask, wake_cause;
  logic [7:0]       seq_delay;
  logic [15:0]      pd_count;
  logic [31:0]      cpu_win [4];

  state_e           state;
  logic [2:0]       step;
  logic [7:0]       dly_cnt;
  logic             mode_deep;     // latched RET_EN at WFI
  logic             wfi_q;

  wire              wfi_rise   = cpu_wfi_i & ~wfi_q;
  wire [IRQ_W-1:0]  wake_hit   = wake_irq_i & wake_mask;
  wire              wake       = |wake_hit;
  wire              dly_done   = (dly_cnt == 8'd0);
  wire [7:0]        dly_load   = (seq_delay == 8'd0) ? 8'd0 : seq_delay - 8'd1;
  wire              dvfs_pend  = (dvfs_tgt != dvfs_sel_o);
  wire              cpu_up     = (state == ST_RUN);

  // ---------------------------------------------------------------------------
  // AXI4-Lite write decode (AW and W accepted independently, one outstanding)
  // ---------------------------------------------------------------------------
  logic        aw_full, w_full;
  logic [31:0] aw_addr_q, w_data_q;
  logic [3:0]  w_strb_q;

  assign s_axi_awready = ~aw_full & ~s_axi_bvalid;
  assign s_axi_wready  = ~w_full  & ~s_axi_bvalid;

  wire        wr_fire = aw_full & w_full & ~s_axi_bvalid;
  wire [11:0] wr_off  = aw_addr_q[11:0];
  // Byte lane 0 after write strobes (only lane used by write-1-to-clear)
  wire [7:0]  wr_data_b0 = w_strb_q[0] ? w_data_q[7:0] : 8'h00;

  logic [1:0] wr_resp;
  always_comb begin
    wr_resp = RESP_OKAY;
    if (aw_addr_q[31:12] != '0 || aw_addr_q[1:0] != 2'b00) wr_resp = RESP_DECERR;
    else if (wr_off >= A_CPU_WIN && wr_off < A_CPU_WIN + 12'h010) begin
      if (!cpu_up && BUG_MODE != 2) wr_resp = RESP_SLVERR;
    end else begin
      unique case (wr_off)
        A_ID, A_STATUS, A_PD_COUNT, A_CTRL, A_WAKE_MASK, A_WAKE_CAUSE, A_SEQ_DELAY: ;
        A_DVFS:  if (w_strb_q[0] && w_data_q[1:0] == 2'd3) wr_resp = RESP_SLVERR; // reserved OPP
        default: wr_resp = RESP_DECERR;
      endcase
    end
  end
  wire wr_okay = (wr_resp == RESP_OKAY);

  // ---------------------------------------------------------------------------
  // Isolation cells
  // ---------------------------------------------------------------------------
  generate
    if (BUG_MODE == 3) begin : g_iso_bug
      assign pd_cpu_out_iso_o = pd_cpu_out_i;
    end else begin : g_iso
      assign pd_cpu_out_iso_o = cpu_iso_en_o ? ISO_CLAMP : pd_cpu_out_i;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Power sequencer
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      state        <= ST_PU;          // cold boot: bring PD_CPU up
      step         <= 3'd0;
      dly_cnt      <= 8'd3;
      mode_deep    <= 1'b0;
      wfi_q        <= 1'b0;
      cpu_clk_en_o <= 1'b0;
      cpu_iso_en_o <= 1'b1;
      cpu_ret_en_o <= 1'b0;
      cpu_pwr_en_o <= 1'b0;
      cpu_rst_n_o  <= 1'b0;
      dvfs_sel_o   <= 2'd0;
      pd_count     <= 16'd0;
      wake_cause   <= '0;
    end else begin
      wfi_q <= cpu_wfi_i;
      if (!dly_done) dly_cnt <= dly_cnt - 8'd1;

      unique case (state)
        ST_RUN: begin
          if (wfi_rise) begin
            mode_deep <= ctrl_ret_en;
            dly_cnt   <= dly_load;
            step      <= 3'd0;
            if (ctrl_pd_en) begin
              state <= ST_PD;
              if (BUG_MODE == 1) cpu_iso_en_o <= 1'b1;   // wrong order
              else               cpu_clk_en_o <= 1'b0;
            end else begin
              state        <= ST_IDLE;
              cpu_clk_en_o <= 1'b0;
            end
          end
        end

        ST_IDLE: begin
          // DVFS: the mux is only switched while the clock is gated in IDLE.
          if (dvfs_pend && (dly_done || wake)) begin
            dvfs_sel_o <= dvfs_tgt;
            dly_cnt    <= dly_load;
          end else if (wake && dly_done) begin
            wake_cause   <= wake_cause | wake_hit;
            cpu_clk_en_o <= 1'b1;
            state        <= ST_RUN;
          end
        end

        ST_PD: begin
          if (dly_done) begin
            dly_cnt <= dly_load;
            step    <= step + 3'd1;
            unique case (step)
              3'd0: if (BUG_MODE == 1) cpu_clk_en_o <= 1'b0;
                    else               cpu_iso_en_o <= 1'b1;
              3'd1: cpu_rst_n_o  <= 1'b0;
              3'd2: if (mode_deep) cpu_ret_en_o <= 1'b1;
                    else begin cpu_pwr_en_o <= 1'b0; state <= ST_SLEEP; pd_count <= pd_count + 16'd1; end
              3'd3: begin cpu_pwr_en_o <= 1'b0; state <= ST_DEEP; pd_count <= pd_count + 16'd1; end
              default: ;
            endcase
          end
        end

        ST_SLEEP, ST_DEEP: begin
          if (wake && dly_done) begin
            wake_cause   <= wake_cause | wake_hit;
            cpu_pwr_en_o <= 1'b1;
            state        <= ST_PU;
            step         <= 3'd0;
            dly_cnt      <= dly_load;
          end
        end

        ST_PU: begin
          // step 0: switch on (also the cold-boot entry point)
          // step 1: wait power_good, then retention off (if set)
          // step 2: reset release, 3: isolation off, 4: clock on
          if (dly_done) begin
            unique case (step)
              3'd0: begin cpu_pwr_en_o <= 1'b1; step <= 3'd1; dly_cnt <= dly_load; end
              3'd1: if (cpu_pwr_good_i) begin
                      dly_cnt <= dly_load;
                      if (cpu_ret_en_o) cpu_ret_en_o <= 1'b0;
                      else begin cpu_rst_n_o <= 1'b1; step <= 3'd3; end
                    end
              3'd3: begin cpu_iso_en_o <= 1'b0; step <= 3'd4; dly_cnt <= dly_load; end
              3'd4: begin cpu_clk_en_o <= 1'b1; state <= ST_RUN; end
              default: step <= 3'd0;
            endcase
          end
        end

        default: state <= ST_PU;
      endcase

      // WAKE_CAUSE is write-1-to-clear (bus write handled below has priority)
      if (wr_fire && wr_off == A_WAKE_CAUSE && wr_okay)
        wake_cause <= wake_cause & ~wr_data_b0[IRQ_W-1:0];
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4-Lite write channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      aw_full <= 1'b0; w_full <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= RESP_OKAY;
      aw_addr_q <= '0; w_data_q <= '0; w_strb_q <= '0;
      ctrl_pd_en <= 1'b0; ctrl_ret_en <= 1'b0; dvfs_tgt <= 2'd0;
      wake_mask <= '1; seq_delay <= 8'd4;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin aw_full <= 1'b1; aw_addr_q <= s_axi_awaddr; end
      if (s_axi_wvalid  && s_axi_wready)  begin w_full  <= 1'b1; w_data_q <= s_axi_wdata; w_strb_q <= s_axi_wstrb; end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
      if (wr_fire) begin
        aw_full <= 1'b0; w_full <= 1'b0;
        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= wr_resp;
        if (wr_okay) begin
          unique case (wr_off)
            A_CTRL:      begin
                           if (w_strb_q[0]) begin ctrl_pd_en <= w_data_q[0]; ctrl_ret_en <= w_data_q[1]; end
                         end
            A_DVFS:      if (w_strb_q[0]) dvfs_tgt  <= w_data_q[1:0];
            A_WAKE_MASK: if (w_strb_q[0]) wake_mask <= w_data_q[IRQ_W-1:0];
            A_SEQ_DELAY: if (w_strb_q[0]) seq_delay <= w_data_q[7:0];
            default: ;
          endcase
        end
      end
    end
  end

  // PD_CPU register window: reset whenever PD_CPU is in reset / powered off.
  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      for (int i = 0; i < 4; i++) cpu_win[i] <= '0;
    end else if (!cpu_rst_n_o) begin
      for (int i = 0; i < 4; i++) cpu_win[i] <= '0;
    end else if (wr_fire && wr_okay && wr_off >= A_CPU_WIN && wr_off < A_CPU_WIN + 12'h010 && cpu_up) begin
      for (int b = 0; b < 4; b++)
        if (w_strb_q[b]) cpu_win[wr_off[3:2]][8*b +: 8] <= w_data_q[8*b +: 8];
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4-Lite read channel
  // ---------------------------------------------------------------------------
  assign s_axi_arready = ~s_axi_rvalid;

  logic [31:0] rd_data;
  logic [1:0]  rd_resp;
  wire  [11:0] rd_off = s_axi_araddr[11:0];
  always_comb begin
    rd_data = '0;
    rd_resp = RESP_OKAY;
    if (s_axi_araddr[31:12] != '0 || s_axi_araddr[1:0] != 2'b00) rd_resp = RESP_DECERR;
    else if (rd_off >= A_CPU_WIN && rd_off < A_CPU_WIN + 12'h010) begin
      if (!cpu_up && BUG_MODE != 2) rd_resp = RESP_SLVERR;
      else                          rd_data = cpu_win[rd_off[3:2]];
    end else begin
      unique case (rd_off)
        A_ID:         rd_data = ID_VALUE;
        A_CTRL:       rd_data = {30'd0, ctrl_ret_en, ctrl_pd_en};
        A_STATUS:     rd_data = {15'd0, dvfs_pend, 2'd0, dvfs_sel_o, 2'd0,
                                 cpu_rst_n_o, cpu_pwr_good_i, cpu_pwr_en_o, cpu_ret_en_o,
                                 cpu_iso_en_o, cpu_clk_en_o, 1'b0, state};
        A_DVFS:       rd_data = {30'd0, dvfs_tgt};
        A_WAKE_MASK:  rd_data = {{(32-IRQ_W){1'b0}}, wake_mask};
        A_WAKE_CAUSE: rd_data = {{(32-IRQ_W){1'b0}}, wake_cause};
        A_SEQ_DELAY:  rd_data = {24'd0, seq_delay};
        A_PD_COUNT:   rd_data = {16'd0, pd_count};
        default:      rd_resp = RESP_DECERR;
      endcase
    end
  end

  always_ff @(posedge clk_aon or negedge rst_aon_n) begin
    if (!rst_aon_n) begin
      s_axi_rvalid <= 1'b0; s_axi_rdata <= '0; s_axi_rresp <= RESP_OKAY;
    end else begin
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rdata  <= rd_data;
        s_axi_rresp  <= rd_resp;
      end
    end
  end

  // Unused inputs (protection type is not checked by this stub)
  wire unused_ok = &{1'b0, s_axi_awprot, s_axi_arprot};

endmodule
