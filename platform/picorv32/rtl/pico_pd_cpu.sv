// PD_CPU of the PicoRV32 bring-up platform: core, I-cache, D-cache, cache
// maintenance registers and the CPU half of the CDC bridge.
//
// CPU-domain address decode:
//   0x0000_0000-0x0000_3FFF  boot ROM   (I-cacheable)
//   0x2000_0000-0x2001_FFFF  RAM        (I- and D-cacheable)
//   0x5000_0000-0x5000_00FF  cache control registers (local)
//   everything else          uncached, forwarded to PD_AON
//
// Cache control registers (0x5000_0000):
//   0x00 CTRL       [0] I$ enable  [1] D$ enable          (reset 0)
//   0x04 DC_CMD     write: D$ command (see pico_cache), blocks until done
//   0x08 IC_CMD     write: I$ command, blocks until done
//   0x0C LINE_ADDR  address for *_LINE commands
//   0x10 DC_HIT  0x14 DC_MISS  0x18 DC_WB  0x1C IC_HIT  0x20 IC_MISS
//                   statistics, write any value to clear
//   0x3C INFO       {8'(ways=2), 8'(line bytes=16), 16'(sets=128)}
module pico_pd_cpu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pwr,
    // interrupts (asynchronous, from PD_AON)
    input  logic        irq_mtip,
    input  logic        irq_msip,
    input  logic        irq_meip,
    // bus crossing to PD_AON
    output logic        x_req,
    output logic [31:0] x_addr,
    output logic [31:0] x_wdata,
    output logic [3:0]  x_wstrb,
    input  logic        x_ack,
    input  logic [31:0] x_rdata,
    // status
    output logic        wfi,
    output logic        trap
);
    // ---------------- core ----------------------------------------------
    logic        mem_valid, mem_instr, mem_ready;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        mtip_s, msip_s, meip_s;
    logic [31:0] irq;

    tc_sync u_s_mtip (.clk(clk), .rst_n(rst_n), .d(irq_mtip), .q(mtip_s));
    tc_sync u_s_msip (.clk(clk), .rst_n(rst_n), .d(irq_msip), .q(msip_s));
    tc_sync u_s_meip (.clk(clk), .rst_n(rst_n), .d(irq_meip), .q(meip_s));

    // irq[0..2] are PicoRV32-internal (timer, ebreak/ecall/illegal, bus error)
    assign irq = {26'd0, meip_s, msip_s, mtip_s, 3'd0};

    /* verilator lint_off PINCONNECTEMPTY */
    picorv32 #(
        .ENABLE_COUNTERS   (1),
        .ENABLE_COUNTERS64 (1),
        .ENABLE_REGS_16_31 (1),
        .ENABLE_REGS_DUALPORT(1),
        .BARREL_SHIFTER    (1),
        .COMPRESSED_ISA    (0),
        .CATCH_MISALIGN    (1),
        .CATCH_ILLINSN     (1),
        .ENABLE_PCPI       (0),
        .ENABLE_MUL        (1),
        .ENABLE_FAST_MUL   (0),
        .ENABLE_DIV        (1),
        .ENABLE_IRQ        (1),
        .ENABLE_IRQ_QREGS  (1),
        .ENABLE_IRQ_TIMER  (0),
        .MASKED_IRQ        (32'h0000_0000),
        .LATCHED_IRQ       (32'h0000_0007),   // external lines are level
        .PROGADDR_RESET    (32'h0000_0000),
        .PROGADDR_IRQ      (32'h0000_0010)
    ) u_core (
        .clk(clk), .resetn(rst_n), .trap(trap),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(irq), .eoi(),
        .trace_valid(), .trace_data(),
        .wfi(wfi)
    );
    /* verilator lint_on PINCONNECTEMPTY */

`ifndef SYNTHESIS
    // OFF-state corruption model for the register file (incl. q-registers).
    always @(negedge pwr) begin
        for (int i = 0; i < 36; i++) u_core.cpuregs[i] = $urandom;
    end
`endif

    // ---------------- decode --------------------------------------------
    wire in_rom  = (mem_addr[31:14] == 18'h0);
    wire in_ram  = (mem_addr[31:17] == 15'h1000);           // 0x2000_0000 + 128K
    wire in_creg = (mem_addr[31:8]  == 24'h50_0000);
    wire sel_ic  = mem_valid &&  mem_instr && (in_rom || in_ram);
    wire sel_dc  = mem_valid && !mem_instr && in_ram;
    wire sel_cr  = mem_valid && !mem_instr && in_creg;
    wire sel_unc = mem_valid && !sel_ic && !sel_dc && !sel_cr;

    // ---------------- cache control registers --------------------------
    logic        ic_en, dc_en;
    logic [31:0] line_addr;
    logic [31:0] cnt_dhit, cnt_dmiss, cnt_dwb, cnt_ihit, cnt_imiss;
    logic        dm_valid, im_valid, dm_done, im_done;
    logic [2:0]  m_cmd;
    logic [31:0] m_addr;
    logic        cr_busy;
    logic        cr_ready;
    logic [31:0] cr_rdata;
    logic        d_hit, d_miss, d_wb, i_hit, i_miss, i_wb_unused;

    wire [5:0] cr_a = mem_addr[7:2];
    wire       cr_we = |mem_wstrb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ic_en <= 1'b0; dc_en <= 1'b0; line_addr <= '0;
            cnt_dhit <= '0; cnt_dmiss <= '0; cnt_dwb <= '0; cnt_ihit <= '0; cnt_imiss <= '0;
            dm_valid <= 1'b0; im_valid <= 1'b0; m_cmd <= '0; m_addr <= '0;
            cr_busy <= 1'b0; cr_ready <= 1'b0; cr_rdata <= '0;
        end else begin
            cr_ready <= 1'b0;
            dm_valid <= 1'b0;
            im_valid <= 1'b0;
            if (d_hit)  cnt_dhit  <= cnt_dhit + 1;
            if (d_miss) cnt_dmiss <= cnt_dmiss + 1;
            if (d_wb)   cnt_dwb   <= cnt_dwb + 1;
            if (i_hit)  cnt_ihit  <= cnt_ihit + 1;
            if (i_miss) cnt_imiss <= cnt_imiss + 1;
            if (sel_cr && !cr_busy && !cr_ready) begin
                if (cr_we) begin
                    unique case (cr_a)
                        6'h00: begin ic_en <= mem_wdata[0]; dc_en <= mem_wdata[1]; cr_ready <= 1'b1; end
                        6'h01: begin dm_valid <= 1'b1; m_cmd <= mem_wdata[2:0]; m_addr <= line_addr; cr_busy <= 1'b1; end
                        6'h02: begin im_valid <= 1'b1; m_cmd <= mem_wdata[2:0]; m_addr <= line_addr; cr_busy <= 1'b1; end
                        6'h03: begin line_addr <= mem_wdata; cr_ready <= 1'b1; end
                        6'h04: begin cnt_dhit  <= '0; cr_ready <= 1'b1; end
                        6'h05: begin cnt_dmiss <= '0; cr_ready <= 1'b1; end
                        6'h06: begin cnt_dwb   <= '0; cr_ready <= 1'b1; end
                        6'h07: begin cnt_ihit  <= '0; cr_ready <= 1'b1; end
                        6'h08: begin cnt_imiss <= '0; cr_ready <= 1'b1; end
                        default: cr_ready <= 1'b1;
                    endcase
                end else begin
                    unique case (cr_a)
                        6'h00: cr_rdata <= {30'd0, dc_en, ic_en};
                        6'h03: cr_rdata <= line_addr;
                        6'h04: cr_rdata <= cnt_dhit;
                        6'h05: cr_rdata <= cnt_dmiss;
                        6'h06: cr_rdata <= cnt_dwb;
                        6'h07: cr_rdata <= cnt_ihit;
                        6'h08: cr_rdata <= cnt_imiss;
                        6'h0F: cr_rdata <= {8'd2, 8'd16, 16'd128};
                        default: cr_rdata <= '0;
                    endcase
                    cr_ready <= 1'b1;
                end
            end
            if (cr_busy && (dm_done || im_done)) begin
                cr_busy  <= 1'b0;
                cr_ready <= 1'b1;
            end
        end
    end

    // ---------------- caches --------------------------------------------
    logic        ic_ready, dc_ready;
    logic [31:0] ic_rdata, dc_rdata;
    logic        ib_valid, db_valid, ub_valid;
    logic [31:0] ib_addr, db_addr, ib_wdata, db_wdata;
    logic [3:0]  ib_wstrb, db_wstrb;
    logic        ib_ready, db_ready, ub_ready;
    logic [31:0] b_rdata;

    pico_cache #(.WB(1'b0)) u_icache (
        .clk(clk), .rst_n(rst_n), .pwr(pwr), .enable(ic_en),
        .c_valid(sel_ic), .c_addr(mem_addr), .c_wdata(32'd0), .c_wstrb(4'd0),
        .c_ready(ic_ready), .c_rdata(ic_rdata),
        .m_valid(im_valid), .m_cmd(m_cmd), .m_addr(m_addr), .m_done(im_done),
        .b_valid(ib_valid), .b_addr(ib_addr), .b_wdata(ib_wdata), .b_wstrb(ib_wstrb),
        .b_ready(ib_ready), .b_rdata(b_rdata),
        .st_hit(i_hit), .st_miss(i_miss), .st_wb(i_wb_unused));

    pico_cache #(.WB(1'b1)) u_dcache (
        .clk(clk), .rst_n(rst_n), .pwr(pwr), .enable(dc_en),
        .c_valid(sel_dc), .c_addr(mem_addr), .c_wdata(mem_wdata), .c_wstrb(mem_wstrb),
        .c_ready(dc_ready), .c_rdata(dc_rdata),
        .m_valid(dm_valid), .m_cmd(m_cmd), .m_addr(m_addr), .m_done(dm_done),
        .b_valid(db_valid), .b_addr(db_addr), .b_wdata(db_wdata), .b_wstrb(db_wstrb),
        .b_ready(db_ready), .b_rdata(b_rdata),
        .st_hit(d_hit), .st_miss(d_miss), .st_wb(d_wb));

    // ---------------- arbiter towards the bridge ------------------------
    // Requests are held until ready; the owner is locked for the transfer.
    logic [1:0]  owner;   // 0 none, 1 icache, 2 dcache, 3 uncached
    logic        x_valid;
    logic [31:0] x_a, x_wd;
    logic [3:0]  x_ws;
    logic        x_ready;
    logic [1:0]  pick;

    assign ub_valid = sel_unc;
    always_comb begin
        if (owner != 2'd0)  pick = owner;
        else if (db_valid)  pick = 2'd2;
        else if (ib_valid)  pick = 2'd1;
        else if (ub_valid)  pick = 2'd3;
        else                pick = 2'd0;
        unique case (pick)
            2'd1:    begin x_valid = ib_valid; x_a = ib_addr;  x_wd = ib_wdata;  x_ws = ib_wstrb;  end
            2'd2:    begin x_valid = db_valid; x_a = db_addr;  x_wd = db_wdata;  x_ws = db_wstrb;  end
            2'd3:    begin x_valid = ub_valid; x_a = mem_addr; x_wd = mem_wdata; x_ws = mem_wstrb; end
            default: begin x_valid = 1'b0;     x_a = '0;       x_wd = '0;        x_ws = '0;        end
        endcase
        ib_ready = (pick == 2'd1) && x_ready;
        db_ready = (pick == 2'd2) && x_ready;
        ub_ready = (pick == 2'd3) && x_ready;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) owner <= 2'd0;
        else if (x_ready) owner <= 2'd0;
        else if (x_valid) owner <= pick;
    end

    logic bridge_idle_unused;
    logic x_ready_q;
    bus_cdc_cpu u_bridge (
        .clk(clk), .rst_n(rst_n),
        .s_valid(x_valid && !x_ready_q), .s_addr(x_a), .s_wdata(x_wd), .s_wstrb(x_ws),
        .s_ready(x_ready), .s_rdata(b_rdata),
        .x_req(x_req), .x_addr(x_addr), .x_wdata(x_wdata), .x_wstrb(x_wstrb),
        .x_ack(x_ack), .x_rdata(x_rdata), .idle(bridge_idle_unused));

    // A requester drops valid in the cycle after ready; block re-issue then.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) x_ready_q <= 1'b0;
        else        x_ready_q <= x_ready;
    end

    // ---------------- response mux to the core --------------------------
    always_comb begin
        mem_ready = 1'b0;
        mem_rdata = b_rdata;
        if (sel_ic)      begin mem_ready = ic_ready; mem_rdata = ic_rdata; end
        else if (sel_dc) begin mem_ready = dc_ready; mem_rdata = dc_rdata; end
        else if (sel_cr) begin mem_ready = cr_ready; mem_rdata = cr_rdata; end
        else if (sel_unc)begin mem_ready = ub_ready; mem_rdata = b_rdata;  end
    end
endmodule
