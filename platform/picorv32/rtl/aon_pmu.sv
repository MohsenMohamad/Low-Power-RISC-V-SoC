// Power management unit (PD_AON).
//
// Power states of PD_CPU: RUN, IDLE (clock gated on WFI), SLEEP (power off),
// DEEP_SLEEP (power off + RAM retention), plus DVFS operating-point changes
// that are only carried out while the CPU clock is gated (IDLE).
//
// Sequences (each step waits for the previous one to be acknowledged):
//   power-down: WFI -> clock gate -> isolation on -> reset -> switch off
//               [-> RAM retention]
//   wake-up   : wake event [-> RAM retention exit] -> switch on -> power_good
//               -> reset release -> isolation off -> clock on
//   DVFS      : WFI -> clock gate -> (raise V) -> clock mux -> (lower V)
//               -> DVFS_DONE event -> clock on
//
// Registers (byte offsets):
//   0x00 CTRL      [1:0] MODE for next WFI (0 IDLE, 1 SLEEP, 2 DEEP_SLEEP)
//                  [4]   DVFS_REQ (with MODE=IDLE). Cleared when done.
//   0x04 STATUS    [1:0] CUR_OP [3:2] VSEL [8:4] FSM state [9] PD_CPU pgood
//   0x08 WAKE_EN   [0] MTIP [1] MSIP [2] MEIP (sleep-state wake sources)
//   0x0C DVFS_OP   [1:0] target operating point (0 fastest .. 2 slowest)
//   0x10 RST_CAUSE cause of last PD_CPU reset: 1 POR, 2 wake from SLEEP,
//                  3 wake from DEEP_SLEEP, 4 software reset
//   0x14 EVENT     W1C [0] DVFS_DONE [1] SLEEP_ABORTED
//   0x18 EVENT_IE  interrupt enables for EVENT (PMU irq -> intc source 1)
//   0x1C SWRST     write 0x5AFE0001: reset PD_CPU (no power cycle)
//   0x20 CNT_IDLE  0x24 CNT_SLEEP  0x28 CNT_DEEP  0x2C CNT_DVFS
//   0x30 CNT_ABORT                 (write any value to clear)
//   0x34 OFF_TIME  clk_aon cycles PD_CPU was off during the last sleep
//   0x38 WAKE_SRC  wake sources active when the last sleep ended
//   0x3C ID        0x504D5531 ("PMU1")
module aon_pmu #(
    parameter int unsigned RET_EXIT_CYCLES = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    // register port
    input  logic        req,
    input  logic        we,
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [11:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        irq,
    // CPU / bus status
    input  logic        cpu_wfi,     // from PD_CPU (isolated), asynchronous
    input  logic        bus_idle,    // AON side of the CDC bridge idle
    input  logic        irq_mtip,
    input  logic        irq_msip,
    input  logic        irq_meip,
    // clock control
    output logic        cg_en,       // CPU clock enable request
    input  logic        cg_ack,      // CPU clock running (asynchronous)
    output logic [1:0]  clk_sel,
    input  logic [2:0]  clk_active,  // one-hot, asynchronous
    output logic [1:0]  vsel,
    input  logic        vok,
    // power control
    output logic        iso_en,
    output logic        cpu_rst_n,
    output logic        psw_en,
    input  logic        pgood,
    output logic        ram_ret
);
    typedef enum logic [4:0] {
        P_POR, P_RUN, P_CG, P_IDLE, P_DV_V1, P_DV_MUX, P_DV_V2, P_UNGATE,
        P_ISO, P_RST, P_PSW_OFF, P_OFF, P_RET_EXIT, P_PSW_ON, P_RST_REL,
        P_ISO_OFF, P_CLK_ON, P_SWRST_WAIT, P_SWRST
    } pst_t;
    pst_t st;

    localparam logic [2:0] RC_POR = 3'd1, RC_SLEEP = 3'd2, RC_DEEP = 3'd3, RC_SWRST = 3'd4;
    localparam logic [1:0] M_IDLE = 2'd0, M_DEEP = 2'd2;   // 1 = SLEEP

    logic wfi_s, ack_s;
    logic [2:0] act_s;
    tc_sync u_s_wfi (.clk(clk), .rst_n(rst_n), .d(cpu_wfi), .q(wfi_s));
    tc_sync #(.RESET_VAL(1'b1)) u_s_ack (.clk(clk), .rst_n(rst_n), .d(cg_ack), .q(ack_s));
    for (genvar i = 0; i < 3; i++) begin : g_act
        tc_sync #(.RESET_VAL(i == 0)) u_s_act (.clk(clk), .rst_n(rst_n), .d(clk_active[i]), .q(act_s[i]));
    end

    logic [1:0]  mode;
    logic        dvfs_req;
    logic [2:0]  wake_en;
    logic [1:0]  dvfs_op, cur_op;
    logic [2:0]  rst_cause;
    logic [1:0]  event_q, event_ie;
    logic [31:0] cnt_idle, cnt_sleep, cnt_deep, cnt_dvfs, cnt_abort, off_time;
    logic [2:0]  wake_src;
    logic [7:0]  tmr;
    logic        deep;      // current sleep is DEEP_SLEEP

    wire [2:0] irq_vec  = {irq_meip, irq_msip, irq_mtip};
    wire       irq_any  = |irq_vec;
    wire [2:0] wake_hit = irq_vec & wake_en;

    function automatic logic [1:0] f_vsel(input logic [1:0] op);
        return (op == 2'd0) ? 2'd2 : (op == 2'd1) ? 2'd1 : 2'd0;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= P_POR;
            mode <= M_IDLE; dvfs_req <= 1'b0; wake_en <= '0; dvfs_op <= '0; cur_op <= '0;
            rst_cause <= RC_POR; event_q <= '0; event_ie <= '0;
            cnt_idle <= '0; cnt_sleep <= '0; cnt_deep <= '0; cnt_dvfs <= '0; cnt_abort <= '0;
            off_time <= '0; wake_src <= '0; tmr <= '0; deep <= 1'b0;
            cg_en <= 1'b0; clk_sel <= 2'd0; vsel <= 2'd2;
            iso_en <= 1'b1; cpu_rst_n <= 1'b0; psw_en <= 1'b0; ram_ret <= 1'b0;
            rdata <= '0;
        end else begin
            // ---------------- registers ----------------
            if (req && we) begin
                unique case (addr[5:2])
                    4'h0: begin mode <= (wdata[1:0] == 2'd3) ? M_IDLE : wdata[1:0]; dvfs_req <= wdata[4]; end
                    4'h2: wake_en  <= wdata[2:0];
                    4'h3: dvfs_op  <= (wdata[1:0] == 2'd3) ? 2'd2 : wdata[1:0];
                    4'h5: event_q  <= event_q & ~wdata[1:0];
                    4'h6: event_ie <= wdata[1:0];
                    4'h7: if (wdata == 32'h5AFE_0001 && st == P_RUN) st <= P_SWRST_WAIT;
                    4'h8: cnt_idle  <= '0;
                    4'h9: cnt_sleep <= '0;
                    4'hA: cnt_deep  <= '0;
                    4'hB: cnt_dvfs  <= '0;
                    4'hC: cnt_abort <= '0;
                    default: ;
                endcase
            end
            if (req && !we) begin
                unique case (addr[5:2])
                    4'h0: rdata <= {27'd0, dvfs_req, 2'd0, mode};
                    4'h1: rdata <= {22'd0, pgood, 5'(st), vsel, cur_op};
                    4'h2: rdata <= {29'd0, wake_en};
                    4'h3: rdata <= {30'd0, dvfs_op};
                    4'h4: rdata <= {29'd0, rst_cause};
                    4'h5: rdata <= {30'd0, event_q};
                    4'h6: rdata <= {30'd0, event_ie};
                    4'h8: rdata <= cnt_idle;
                    4'h9: rdata <= cnt_sleep;
                    4'hA: rdata <= cnt_deep;
                    4'hB: rdata <= cnt_dvfs;
                    4'hC: rdata <= cnt_abort;
                    4'hD: rdata <= off_time;
                    4'hE: rdata <= {29'd0, wake_src};
                    4'hF: rdata <= 32'h504D_5531;
                    default: rdata <= '0;
                endcase
            end

            // ---------------- sequencer ----------------
            unique case (st)
                // cold power-up of PD_CPU after AON reset
                P_POR: begin
                    psw_en <= 1'b1;
                    if (pgood) begin
                        rst_cause <= RC_POR;
                        st <= P_RST_REL;
                    end
                end
                P_RUN: begin
                    if (wfi_s && bus_idle && !irq_any) begin
                        cg_en <= 1'b0;
                        st    <= P_CG;
                    end
                end
                P_CG: if (!ack_s) begin
                    if (mode != M_IDLE && (irq_any || wake_en == 3'd0)) begin
                        // wake event already pending / no wake source: do not power down
                        event_q[1] <= 1'b1;
                        cnt_abort  <= cnt_abort + 1;
                        mode       <= M_IDLE;
                        st         <= P_UNGATE;
                    end else if (mode != M_IDLE) begin
                        deep <= (mode == M_DEEP);
                        st   <= P_ISO;
                    end else if (dvfs_req) begin
                        if (f_vsel(dvfs_op) > vsel) begin
                            vsel <= f_vsel(dvfs_op);   // raise voltage before frequency
                            st   <= P_DV_V1;
                        end else begin
                            clk_sel <= dvfs_op;
                            st      <= P_DV_MUX;
                        end
                    end else begin
                        cnt_idle <= cnt_idle + 1;
                        st       <= P_IDLE;
                    end
                end
                P_IDLE: if (irq_any) begin
                    cg_en <= 1'b1;
                    st    <= P_UNGATE;
                end
                P_DV_V1: if (vok) begin
                    clk_sel <= dvfs_op;
                    st      <= P_DV_MUX;
                end
                P_DV_MUX: if (act_s == (3'b001 << clk_sel)) begin
                    vsel <= f_vsel(dvfs_op);       // lower voltage after frequency
                    st   <= P_DV_V2;
                end
                P_DV_V2: if (vok) begin
                    cur_op     <= dvfs_op;
                    dvfs_req   <= 1'b0;
                    event_q[0] <= 1'b1;
                    cnt_dvfs   <= cnt_dvfs + 1;
                    cg_en      <= 1'b1;
                    st         <= P_UNGATE;
                end
                P_UNGATE: begin
                    cg_en <= 1'b1;
                    if (ack_s) st <= P_RUN;
                end
                // ---- power-down ----
                P_ISO: begin
                    iso_en <= 1'b1;
                    st     <= P_RST;
                end
                P_RST: begin
                    cpu_rst_n <= 1'b0;
                    st        <= P_PSW_OFF;
                end
                P_PSW_OFF: begin
                    psw_en <= 1'b0;
                    if (!pgood) begin
                        ram_ret  <= deep;
                        off_time <= '0;
                        st       <= P_OFF;
                    end
                end
                P_OFF: begin
                    off_time <= off_time + 1;
                    if (|wake_hit) begin
                        wake_src <= wake_hit;
                        ram_ret  <= 1'b0;
                        tmr      <= '0;
                        st       <= deep ? P_RET_EXIT : P_PSW_ON;
                    end
                end
                P_RET_EXIT: begin
                    tmr <= tmr + 1'b1;
                    if (tmr == 8'(RET_EXIT_CYCLES)) st <= P_PSW_ON;
                end
                // ---- wake-up ----
                P_PSW_ON: begin
                    psw_en <= 1'b1;
                    if (pgood) begin
                        rst_cause <= deep ? RC_DEEP : RC_SLEEP;
                        if (deep) cnt_deep <= cnt_deep + 1;
                        else      cnt_sleep <= cnt_sleep + 1;
                        mode <= M_IDLE;
                        st   <= P_RST_REL;
                    end
                end
                P_RST_REL: begin
                    cpu_rst_n <= 1'b1;
                    st        <= P_ISO_OFF;
                end
                P_ISO_OFF: begin
                    iso_en <= 1'b0;
                    st     <= P_CLK_ON;
                end
                P_CLK_ON: begin
                    cg_en <= 1'b1;
                    if (ack_s) st <= P_RUN;
                end
                // ---- software reset of PD_CPU ----
                P_SWRST_WAIT: begin
                    tmr <= '0;
                    if (bus_idle) st <= P_SWRST;
                end
                P_SWRST: begin
                    cpu_rst_n <= 1'b0;
                    tmr <= tmr + 1'b1;
                    if (tmr == 8'd15) begin
                        rst_cause <= RC_SWRST;
                        st <= P_RST_REL;
                    end
                end
                default: st <= P_RUN;
            endcase
        end
    end

    assign irq = |(event_q & event_ie);

`ifndef SYNTHESIS
    /* verilator lint_off SYNCASYNCNET */
    // Basic sequencing checks (formal properties live with the PMU RTL proper).
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (!pgood && !iso_en) $error("PMU: PD_CPU unpowered without isolation");
            if (!pgood && cpu_rst_n && st != P_RST_REL) $error("PMU: PD_CPU unpowered out of reset");
            if (ram_ret && psw_en) $error("PMU: RAM in retention while PD_CPU powered");
        end
    end
    /* verilator lint_on SYNCASYNCNET */
`endif
endmodule
