// Asynchronous bus bridge PD_CPU (clk_cpu) -> PD_AON (clk_aon).
//
// Two-phase (toggle) handshake with bundled data:
//   CPU: hold addr/wdata/wstrb, toggle req_t
//   AON: sees req_t != req_seen (2-flop sync), performs the access, holds
//        rdata, toggles ack_t
//   CPU: sees ack_t != ack_seen (2-flop sync), captures rdata
// The bundled data is stable for at least two destination clocks before the
// synchronized toggle is seen.
//
// Power-down safety: isolation clamps the CPU-side outputs to 0 and the AON
// half is held in reset while isolation is on or PD_CPU is in reset, so
// both halves restart from req_t = req_seen = ack_t = ack_seen = 0 and a
// clamped signal can never be mistaken for a request.

module bus_cdc_cpu (
    input  logic        clk,
    input  logic        rst_n,
    // slave port (from CPU-domain interconnect)
    input  logic        s_valid,
    input  logic [31:0] s_addr,
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    output logic        s_ready,
    output logic [31:0] s_rdata,
    // crossing
    output logic        x_req,      // req_t
    output logic [31:0] x_addr,
    output logic [31:0] x_wdata,
    output logic [3:0]  x_wstrb,
    input  logic        x_ack,      // ack_t, asynchronous
    input  logic [31:0] x_rdata,    // stable from the ack toggle to the next request
    output logic        idle
);
    logic busy, ack_s, ack_seen;

    tc_sync u_sync_ack (.clk(clk), .rst_n(rst_n), .d(x_ack), .q(ack_s));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            ack_seen <= 1'b0;
            x_req    <= 1'b0;
            x_addr   <= '0;
            x_wdata  <= '0;
            x_wstrb  <= '0;
        end else if (!busy) begin
            if (s_valid) begin
                x_addr  <= s_addr;
                x_wdata <= s_wdata;
                x_wstrb <= s_wstrb;
                x_req   <= ~x_req;
                busy    <= 1'b1;
            end
        end else if (ack_s != ack_seen) begin
            ack_seen <= ack_s;
            busy     <= 1'b0;
        end
    end

    assign s_ready = busy && (ack_s != ack_seen);
    assign s_rdata = x_rdata;
    assign idle    = !busy;
endmodule

module bus_cdc_aon (
    input  logic        clk,
    input  logic        rst_n,
    // crossing (already isolated)
    input  logic        x_req,      // req_t, asynchronous
    input  logic [31:0] x_addr,
    input  logic [31:0] x_wdata,
    input  logic [3:0]  x_wstrb,
    output logic        x_ack,      // ack_t
    output logic [31:0] x_rdata,
    // master port (to AON interconnect)
    output logic        m_valid,
    output logic [31:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    input  logic        m_ready,
    input  logic [31:0] m_rdata,
    output logic        idle
);
    logic req_s, req_seen, access;

    tc_sync u_sync_req (.clk(clk), .rst_n(rst_n), .d(x_req), .q(req_s));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            access   <= 1'b0;
            req_seen <= 1'b0;
            x_ack    <= 1'b0;
            x_rdata  <= '0;
            m_addr   <= '0;
            m_wdata  <= '0;
            m_wstrb  <= '0;
        end else if (!access) begin
            if (req_s != req_seen) begin
                m_addr   <= x_addr;
                m_wdata  <= x_wdata;
                m_wstrb  <= x_wstrb;
                req_seen <= req_s;
                access   <= 1'b1;
            end
        end else if (m_ready) begin
            x_rdata <= m_rdata;
            x_ack   <= ~x_ack;
            access  <= 1'b0;
        end
    end
    assign m_valid = access;
    assign idle    = !access && (req_s == req_seen);
endmodule
