// 4 KB, 2-way set-associative cache, 16-byte lines, 128 sets.
//
// WB=1: write-back / write-allocate data cache.
// WB=0: read-only instruction cache (writes are not expected).
//
// Tag and data arrays are tc_sram macros inside PD_CPU: their contents are
// lost when the domain is switched off, so firmware must run INV_ALL after
// every power-up before enabling the cache (the boot ROM does this).
//
// Maintenance commands (m_cmd):
//   1 INV_ALL   2 CLEAN_ALL   3 FLUSH_ALL (clean + invalidate)
//   4 INV_LINE  5 CLEAN_LINE  6 FLUSH_LINE   (line containing m_addr)
// m_done pulses for one cycle when the command has completed.
module pico_cache #(
    parameter bit WB = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pwr,        // array supply (simulation model only)
    input  logic        enable,
    // core side
    input  logic        c_valid,
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [3:0]  c_wstrb,
    output logic        c_ready,
    output logic [31:0] c_rdata,
    // maintenance
    input  logic        m_valid,
    input  logic [2:0]  m_cmd,
    input  logic [31:0] m_addr,
    output logic        m_done,
    // memory side (single-word requests, held until b_ready)
    output logic        b_valid,
    output logic [31:0] b_addr,
    output logic [31:0] b_wdata,
    output logic [3:0]  b_wstrb,
    input  logic        b_ready,
    input  logic [31:0] b_rdata,
    // statistics pulses
    output logic        st_hit,
    output logic        st_miss,
    output logic        st_wb
);
    localparam int SETS = 128;
    localparam int TAGW = 21;

    localparam logic [2:0] C_INV_ALL = 3'd1, C_CLEAN_ALL = 3'd2, C_FLUSH_ALL = 3'd3,
                           C_INV_LINE = 3'd4, C_CLEAN_LINE = 3'd5, C_FLUSH_LINE = 3'd6;

    typedef enum logic [3:0] {
        S_IDLE, S_LOOKUP, S_WB_RD, S_WB_REQ, S_REFILL, S_REFILL_TAG,
        S_M_RD, S_M_CHK, S_M_UPD, S_M_DONE
    } state_t;
    state_t st;

    // address fields
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [6:0] f_idx(input logic [31:0] a); return a[10:4]; endfunction
    function automatic logic [TAGW-1:0] f_tag(input logic [31:0] a); return a[31:11]; endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- arrays -------------------------------------------------------
    logic        t_ce [2];
    logic        t_we [2];
    logic [6:0]  t_addr;
    logic [23:0] t_wdata [2];
    logic [23:0] t_rdata [2];
    logic        d_ce [2];
    logic        d_we [2];
    logic [3:0]  d_be;
    logic [8:0]  d_addr;
    logic [31:0] d_wdata;
    logic [31:0] d_rdata [2];

    for (genvar w = 0; w < 2; w++) begin : g_way
        tc_sram #(.DEPTH(SETS), .W(24)) u_tag (
            .clk(clk), .ce(t_ce[w]), .we(t_we[w]), .be(3'b111), .addr(t_addr),
            .wdata(t_wdata[w]), .rdata(t_rdata[w]), .pwr(pwr), .ret(1'b0));
        tc_sram #(.DEPTH(SETS*4), .W(32)) u_data (
            .clk(clk), .ce(d_ce[w]), .we(d_we[w]), .be(d_be), .addr(d_addr),
            .wdata(d_wdata), .rdata(d_rdata[w]), .pwr(pwr), .ret(1'b0));
    end

    // tag entry: [23] valid, [22] dirty, [20:0] tag
    logic            tv [2];
    logic            td [2];
    logic [TAGW-1:0] tt [2];
    always_comb begin
        for (int w = 0; w < 2; w++) begin
            tv[w] = t_rdata[w][23];
            td[w] = t_rdata[w][22] & WB;
            tt[w] = t_rdata[w][TAGW-1:0];
        end
    end

    logic [SETS-1:0] lru;   // way to replace next

    // ---- registers ----------------------------------------------------
    logic            r_way;      // victim / target way
    logic [6:0]      r_idx;
    logic [TAGW-1:0] r_vtag;     // tag of line being written back
    logic [1:0]      r_word;
    logic            r_maint;    // write-back belongs to a maintenance op
    logic [2:0]      r_cmd;
    logic [6:0]      r_set;
    logic            r_mway;
    logic [TAGW-1:0] r_mtag;
    logic            r_replay;   // lookup after a refill (not a new access)

    wire [6:0]      req_idx = f_idx(c_addr);
    wire [TAGW-1:0] req_tag = f_tag(c_addr);
    wire            hit0 = tv[0] && (tt[0] == req_tag);
    wire            hit1 = tv[1] && (tt[1] == req_tag);
    wire            hit  = hit0 | hit1;
    wire            hway = hit1;
    wire            is_all = (r_cmd == C_INV_ALL) || (r_cmd == C_CLEAN_ALL) || (r_cmd == C_FLUSH_ALL);
    wire            do_inv = (r_cmd == C_INV_ALL) || (r_cmd == C_FLUSH_ALL) ||
                             (r_cmd == C_INV_LINE) || (r_cmd == C_FLUSH_LINE);
    wire            do_clean = (r_cmd == C_CLEAN_ALL) || (r_cmd == C_FLUSH_ALL) ||
                               (r_cmd == C_CLEAN_LINE) || (r_cmd == C_FLUSH_LINE);
    // maintenance: which way is examined and is it a match
    wire            m_lhit0 = tv[0] && (tt[0] == r_mtag);
    wire            m_lhit1 = tv[1] && (tt[1] == r_mtag);
    wire            m_way   = is_all ? r_mway : m_lhit1;
    wire            m_sel   = is_all ? 1'b1 : (m_lhit0 | m_lhit1);

    // ---- combinational control -----------------------------------------
    always_comb begin
        for (int w = 0; w < 2; w++) begin
            t_ce[w] = 1'b0; t_we[w] = 1'b0; t_wdata[w] = '0;
            d_ce[w] = 1'b0; d_we[w] = 1'b0;
        end
        t_addr  = req_idx;
        d_addr  = {req_idx, c_addr[3:2]};
        d_be    = 4'hf;
        d_wdata = c_wdata;
        c_ready = 1'b0;
        c_rdata = hway ? d_rdata[1] : d_rdata[0];
        b_valid = 1'b0;
        b_addr  = '0;
        b_wdata = d_rdata[r_way];
        b_wstrb = 4'h0;
        m_done  = 1'b0;
        st_hit = 1'b0; st_miss = 1'b0; st_wb = 1'b0;

        unique case (st)
            S_IDLE: begin
                if (m_valid) begin
                    // handled in sequential block
                end else if (c_valid && !enable) begin
                    // cache disabled: pass straight through
                    b_valid = 1'b1;
                    b_addr  = c_addr;
                    b_wdata = c_wdata;
                    b_wstrb = c_wstrb;
                    c_ready = b_ready;
                    c_rdata = b_rdata;
                end else if (c_valid) begin
                    for (int w = 0; w < 2; w++) begin
                        t_ce[w] = 1'b1;
                        d_ce[w] = 1'b1;
                    end
                end
            end
            S_LOOKUP: begin
                if (hit) begin
                    c_ready = 1'b1;
                    st_hit  = !r_replay;
                    if (|c_wstrb) begin
                        d_ce[hway] = 1'b1;
                        d_we[hway] = 1'b1;
                        d_be       = c_wstrb;
                        if (WB) begin
                            t_ce[hway]    = 1'b1;
                            t_we[hway]    = 1'b1;
                            t_wdata[hway] = {1'b1, 1'b1, 1'b0, req_tag};
                        end
                    end
                end else begin
                    st_miss = 1'b1;
                end
            end
            S_WB_RD: begin
                d_ce[r_way] = 1'b1;
                d_addr      = {r_idx, r_word};
            end
            S_WB_REQ: begin
                b_valid = 1'b1;
                b_addr  = {r_vtag, r_idx, r_word, 2'b00};
                b_wdata = d_rdata[r_way];
                b_wstrb = 4'hf;
                if (b_ready && r_word == 2'd3) st_wb = 1'b1;
            end
            S_REFILL: begin
                b_valid = 1'b1;
                b_addr  = {req_tag, r_idx, r_word, 2'b00};
                if (b_ready) begin
                    d_ce[r_way] = 1'b1;
                    d_we[r_way] = 1'b1;
                    d_addr      = {r_idx, r_word};
                    d_wdata     = b_rdata;
                end
            end
            S_REFILL_TAG: begin
                t_ce[r_way]    = 1'b1;
                t_we[r_way]    = 1'b1;
                t_addr         = r_idx;
                t_wdata[r_way] = {1'b1, 1'b0, 1'b0, req_tag};
            end
            S_M_RD: begin
                t_ce[0] = 1'b1; t_ce[1] = 1'b1;
                t_addr  = r_set;
            end
            S_M_CHK: ;
            S_M_UPD: begin
                t_addr = r_set;
                if (r_cmd == C_INV_ALL) begin
                    // discard everything, including garbage after power-up
                    t_ce[r_way] = 1'b1; t_we[r_way] = 1'b1; t_wdata[r_way] = '0;
                end else if (m_sel) begin
                    t_ce[r_way] = 1'b1; t_we[r_way] = 1'b1;
                    t_wdata[r_way] = do_inv ? 24'h0
                                   : {tv[r_way], 1'b0, 1'b0, tt[r_way]};
                end
            end
            S_M_DONE: m_done = 1'b1;
            default: ;
        endcase
    end

    // ---- sequential control ---------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            lru     <= '0;
            r_way   <= 1'b0;
            r_idx   <= '0;
            r_vtag  <= '0;
            r_word  <= '0;
            r_maint <= 1'b0;
            r_cmd   <= '0;
            r_set   <= '0;
            r_mway  <= 1'b0;
            r_mtag  <= '0;
            r_replay <= 1'b0;
        end else begin
            unique case (st)
                S_IDLE: begin
                    if (m_valid) begin
                        r_cmd   <= m_cmd;
                        r_mway  <= 1'b0;
                        r_mtag  <= f_tag(m_addr);
                        r_set   <= (m_cmd >= C_INV_LINE) ? f_idx(m_addr) : 7'd0;
                        r_maint <= 1'b1;
                        st      <= S_M_RD;
                    end else if (c_valid && enable) begin
                        st <= S_LOOKUP;
                    end
                end
                S_LOOKUP: begin
                    r_replay <= 1'b0;
                    if (hit) begin
                        lru[req_idx] <= ~hway;
                        st <= S_IDLE;
                    end else begin
                        logic vw;
                        vw = !tv[0] ? 1'b0 : !tv[1] ? 1'b1 : lru[req_idx];
                        r_way   <= vw;
                        r_idx   <= req_idx;
                        r_vtag  <= tt[vw];
                        r_word  <= 2'd0;
                        r_maint <= 1'b0;
                        st      <= (WB && tv[vw] && td[vw]) ? S_WB_RD : S_REFILL;
                    end
                end
                S_WB_RD: st <= S_WB_REQ;
                S_WB_REQ: begin
                    if (b_ready) begin
                        r_word <= r_word + 2'd1;
                        if (r_word == 2'd3) st <= r_maint ? S_M_UPD : S_REFILL;
                        else                st <= S_WB_RD;
                    end
                end
                S_REFILL: begin
                    if (b_ready) begin
                        r_word <= r_word + 2'd1;
                        if (r_word == 2'd3) st <= S_REFILL_TAG;
                    end
                end
                S_REFILL_TAG: begin
                    lru[r_idx] <= ~r_way;
                    r_replay   <= 1'b1;
                    st <= S_IDLE;      // core request is replayed and now hits
                end
                S_M_RD: st <= S_M_CHK;
                S_M_CHK: begin
                    r_way <= m_way;
                    r_idx <= r_set;
                    if (r_cmd != C_INV_ALL && m_sel && do_clean && tv[m_way] && td[m_way]) begin
                        r_vtag <= tt[m_way];
                        r_word <= 2'd0;
                        st     <= S_WB_RD;
                    end else begin
                        st <= S_M_UPD;
                    end
                end
                S_M_UPD: begin
                    if (is_all && !r_mway) begin
                        r_mway <= 1'b1;
                        st     <= S_M_CHK;   // tag read data is still valid
                    end else if (is_all && r_set != 7'(SETS - 1)) begin
                        r_mway <= 1'b0;
                        r_set  <= r_set + 7'd1;
                        st     <= S_M_RD;
                    end else begin
                        st <= S_M_DONE;
                    end
                end
                S_M_DONE: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
