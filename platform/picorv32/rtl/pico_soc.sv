// PicoRV32-based firmware bring-up version of the low-power SoC.
//
//   PD_CPU (switchable, clk_cpu): PicoRV32 RV32IM, 4 KB I$, 4 KB D$
//   PD_AON (always on, clk_aon) : boot ROM 16 KB, RAM 128 KB (retention),
//                                 UART, machine/wake timer, intc, PMU
//   clk_cpu = gate(glitch-free mux(clk_ref, clk_ref/2, clk_ref/4))
//
// AON memory map:
//   0x0000_0000 boot ROM          0x4000_0000 UART
//   0x2000_0000 RAM (cacheable)   0x4000_1000 interrupt controller
//   0x3000_0000 RAM (uncached)    0x4000_2000 PMU
//   0x4F00_0000 external port     0x4001_0000 machine timer (CLINT layout)
module pico_soc #(
    parameter logic [15:0] UART_DIV = 16'd8,
    parameter int unsigned PSW_RAMP_ON = 16,
    parameter int unsigned VREG_SETTLE = 32
) (
    input  logic        clk_aon,
    input  logic        clk_ref,
    input  logic        por_n,
    input  logic        uart_rxd,
    output logic        uart_txd,
    // external port (board / testbench devices), one-cycle strobe protocol
    output logic        ext_req,
    output logic        ext_we,
    output logic [15:0] ext_addr,
    output logic [31:0] ext_wdata,
    input  logic [31:0] ext_rdata,
    // observability
    output logic        cpu_trap,
    output logic        cpu_pwr,
    output logic        cpu_iso,
    output logic        ram_ret
);
    // ================= resets =================
    logic rst_aon_n, rst_ref_n, rst_free_n;
    tc_rst_sync u_rs_aon (.clk(clk_aon), .rst_n_in(por_n), .rst_n_out(rst_aon_n));
    tc_rst_sync u_rs_ref (.clk(clk_ref), .rst_n_in(por_n), .rst_n_out(rst_ref_n));

    // ================= clocks =================
    logic clk_div2, clk_div4, clk_free, clk_cpu;
    logic [1:0] clk_sel;
    logic [2:0] clk_active;
    logic cg_en, cg_en_s;

    always_ff @(posedge clk_ref or negedge rst_ref_n)
        if (!rst_ref_n) clk_div2 <= 1'b0; else clk_div2 <= ~clk_div2;
    always_ff @(posedge clk_div2 or negedge rst_ref_n)
        if (!rst_ref_n) clk_div4 <= 1'b0; else clk_div4 <= ~clk_div4;

    tc_clk_mux_gf #(.N(3)) u_clk_mux (
        .clk_in({clk_div4, clk_div2, clk_ref}), .rst_n(rst_ref_n), .sel(clk_sel),
        .clk_out(clk_free), .active(clk_active));

    tc_rst_sync u_rs_free (.clk(clk_free), .rst_n_in(por_n), .rst_n_out(rst_free_n));
    tc_sync     u_cg_sync (.clk(clk_free), .rst_n(rst_free_n), .d(cg_en), .q(cg_en_s));
    tc_clk_gate u_cg      (.clk(clk_free), .en(cg_en_s), .test_en(1'b0), .gclk(clk_cpu));

    // ================= power =================
    logic psw_en, pgood, pwr, iso_en, pmu_cpu_rst_n, rst_cpu_n;
    logic [1:0] vsel;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0] vlevel;     // delivered level, observability only
    /* verilator lint_on UNUSEDSIGNAL */
    logic vok;

    tc_pwr_switch #(.RAMP_ON(PSW_RAMP_ON)) u_psw (
        .clk(clk_aon), .rst_n(rst_aon_n), .en(psw_en), .pgood(pgood), .pwr(pwr));
    tc_vreg #(.SETTLE(VREG_SETTLE)) u_vreg (
        .clk(clk_aon), .rst_n(rst_aon_n), .vsel(vsel), .vlevel(vlevel), .vok(vok));

    // PD_CPU reset: asynchronous assert, de-assert synchronous to clk_cpu
    tc_rst_sync u_rs_cpu (.clk(clk_cpu), .rst_n_in(rst_aon_n & pmu_cpu_rst_n), .rst_n_out(rst_cpu_n));

    // ================= PD_CPU =================
    logic        c_req, c_wfi, c_trap;
    logic [31:0] c_addr, c_wdata;
    logic [3:0]  c_wstrb;
    logic        x_ack;
    logic [31:0] x_rdata;
    logic        irq_mtip, irq_msip, irq_meip;

    pico_pd_cpu u_pd_cpu (
        .clk(clk_cpu), .rst_n(rst_cpu_n), .pwr(pwr),
        .irq_mtip(irq_mtip), .irq_msip(irq_msip), .irq_meip(irq_meip),
        .x_req(c_req), .x_addr(c_addr), .x_wdata(c_wdata), .x_wstrb(c_wstrb),
        .x_ack(x_ack), .x_rdata(x_rdata), .wfi(c_wfi), .trap(c_trap));

    // ================= isolation (PD_CPU -> PD_AON) =================
    logic        i_req, i_wfi, i_trap;
    logic [31:0] i_addr, i_wdata;
    logic [3:0]  i_wstrb;
    tc_iso #(.W(71)) u_iso (
        .iso_en(iso_en),
        .d({c_req, c_wfi, c_trap, c_addr, c_wdata, c_wstrb}),
        .q({i_req, i_wfi, i_trap, i_addr, i_wdata, i_wstrb}));

    // ================= PD_AON =================
    logic br_rst_n;
    always_ff @(posedge clk_aon or negedge rst_aon_n)
        if (!rst_aon_n) br_rst_n <= 1'b0; else br_rst_n <= !iso_en && pmu_cpu_rst_n;

    logic        m_valid, m_ready, br_idle;
    logic [31:0] m_addr, m_wdata, m_rdata;
    logic [3:0]  m_wstrb;

    bus_cdc_aon u_bridge (
        .clk(clk_aon), .rst_n(br_rst_n),
        .x_req(i_req), .x_addr(i_addr), .x_wdata(i_wdata), .x_wstrb(i_wstrb),
        .x_ack(x_ack), .x_rdata(x_rdata),
        .m_valid(m_valid), .m_addr(m_addr), .m_wdata(m_wdata), .m_wstrb(m_wstrb),
        .m_ready(m_ready), .m_rdata(m_rdata), .idle(br_idle));

    // ---- interconnect: single master, one-cycle registered slaves ----
    typedef enum logic [2:0] {S_NONE, S_ROM, S_RAM, S_UART, S_INTC, S_PMU, S_TMR, S_EXT} sel_t;
    sel_t sel, sel_q;
    logic busy;
    always_comb begin
        sel = S_NONE;
        if      (m_addr[31:14] == 18'h0)                               sel = S_ROM;
        else if (m_addr[31:17] == 15'h1000 || m_addr[31:17] == 15'h1800) sel = S_RAM;
        else if (m_addr[31:12] == 20'h40000)                          sel = S_UART;
        else if (m_addr[31:12] == 20'h40001)                          sel = S_INTC;
        else if (m_addr[31:12] == 20'h40002)                          sel = S_PMU;
        else if (m_addr[31:16] == 16'h4001)                           sel = S_TMR;
        else if (m_addr[31:16] == 16'h4F00)                           sel = S_EXT;
    end
    wire strobe = m_valid && !busy;
    wire we     = |m_wstrb;
    always_ff @(posedge clk_aon or negedge rst_aon_n) begin
        if (!rst_aon_n) begin busy <= 1'b0; sel_q <= S_NONE; end
        else begin
            busy <= strobe;
            if (strobe) sel_q <= sel;
        end
    end
    assign m_ready = busy;

    logic [31:0] rom_rdata, ram_rdata, uart_rdata, intc_rdata, pmu_rdata, tmr_rdata;
    logic        uart_irq, pmu_irq;

    tc_sram #(.DEPTH(4096), .W(32), .INIT_PLUSARG("rom_hex")) u_rom (
        .clk(clk_aon), .ce(strobe && sel == S_ROM), .we(1'b0), .be(4'h0),
        .addr(m_addr[13:2]), .wdata(32'd0), .rdata(rom_rdata), .pwr(1'b1), .ret(1'b0));

    tc_sram #(.DEPTH(32768), .W(32), .INIT_PLUSARG("ram_hex")) u_ram (
        .clk(clk_aon), .ce(strobe && sel == S_RAM), .we(we), .be(m_wstrb),
        .addr(m_addr[16:2]), .wdata(m_wdata), .rdata(ram_rdata), .pwr(1'b1), .ret(ram_ret));

    aon_uart #(.DIV_RESET(UART_DIV)) u_uart (
        .clk(clk_aon), .rst_n(rst_aon_n), .req(strobe && sel == S_UART), .we(we),
        .addr(m_addr[11:0]), .wdata(m_wdata), .rdata(uart_rdata), .irq(uart_irq),
        .rxd(uart_rxd), .txd(uart_txd));

    aon_intc u_intc (
        .clk(clk_aon), .rst_n(rst_aon_n), .req(strobe && sel == S_INTC), .we(we),
        .addr(m_addr[11:0]), .wdata(m_wdata), .rdata(intc_rdata),
        .src({6'd0, pmu_irq, uart_irq}), .meip(irq_meip));

    aon_timer u_timer (
        .clk(clk_aon), .rst_n(rst_aon_n), .req(strobe && sel == S_TMR), .we(we),
        .addr(m_addr[15:0]), .wdata(m_wdata), .rdata(tmr_rdata),
        .mtip(irq_mtip), .msip(irq_msip));

    aon_pmu u_pmu (
        .clk(clk_aon), .rst_n(rst_aon_n), .req(strobe && sel == S_PMU), .we(we),
        .addr(m_addr[11:0]), .wdata(m_wdata), .rdata(pmu_rdata), .irq(pmu_irq),
        .cpu_wfi(i_wfi), .bus_idle(br_idle),
        .irq_mtip(irq_mtip), .irq_msip(irq_msip), .irq_meip(irq_meip),
        .cg_en(cg_en), .cg_ack(cg_en_s), .clk_sel(clk_sel), .clk_active(clk_active),
        .vsel(vsel), .vok(vok),
        .iso_en(iso_en), .cpu_rst_n(pmu_cpu_rst_n), .psw_en(psw_en), .pgood(pgood),
        .ram_ret(ram_ret));

    assign ext_req   = strobe && sel == S_EXT;
    assign ext_we    = we;
    assign ext_addr  = m_addr[15:0];
    assign ext_wdata = m_wdata;

    always_comb begin
        unique case (sel_q)
            S_ROM:   m_rdata = rom_rdata;
            S_RAM:   m_rdata = ram_rdata;
            S_UART:  m_rdata = uart_rdata;
            S_INTC:  m_rdata = intc_rdata;
            S_PMU:   m_rdata = pmu_rdata;
            S_TMR:   m_rdata = tmr_rdata;
            S_EXT:   m_rdata = ext_rdata;
            default: m_rdata = 32'd0;
        endcase
    end

    assign cpu_trap = i_trap;
    assign cpu_pwr  = pgood;
    assign cpu_iso  = iso_en;
endmodule
