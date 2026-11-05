// Asynchronous bus bridge PD_CPU (clk_cpu) -> PD_AON (clk_aon).
//
// Four-phase level handshake with bundled data:
//   CPU: hold addr/wdata/wstrb, req=1 ... AON: access, hold rdata, ack=1
//   CPU: capture rdata, req=0       ... AON: ack=0
// All request signals are clamped to 0 by isolation while PD_CPU is off; a
// clamped request is "idle", so isolation can never create a transfer. The
// AON half is additionally held in reset while isolation is active.

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
    output logic        x_req,
    output logic [31:0] x_addr,
    output logic [31:0] x_wdata,
    output logic [3:0]  x_wstrb,
    input  logic        x_ack,      // asynchronous
    input  logic [31:0] x_rdata,    // stable while x_ack is high
    output logic        idle
);
    typedef enum logic [1:0] {C_IDLE, C_WAIT_ACK, C_WAIT_NACK} cst_t;
    cst_t st;
    logic ack_s;

    tc_sync u_sync_ack (.clk(clk), .rst_n(rst_n), .d(x_ack), .q(ack_s));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= C_IDLE;
            x_req   <= 1'b0;
            x_addr  <= '0;
            x_wdata <= '0;
            x_wstrb <= '0;
        end else begin
            unique case (st)
                C_IDLE: if (s_valid) begin
                    x_addr  <= s_addr;
                    x_wdata <= s_wdata;
                    x_wstrb <= s_wstrb;
                    x_req   <= 1'b1;
                    st      <= C_WAIT_ACK;
                end
                C_WAIT_ACK: if (ack_s) begin
                    x_req <= 1'b0;
                    st    <= C_WAIT_NACK;
                end
                C_WAIT_NACK: if (!ack_s) st <= C_IDLE;
                default: st <= C_IDLE;
            endcase
        end
    end

    // Data is captured in the cycle the synchronized ack is first seen.
    assign s_ready = (st == C_WAIT_ACK) && ack_s;
    assign s_rdata = x_rdata;
    assign idle    = (st == C_IDLE);
endmodule

module bus_cdc_aon (
    input  logic        clk,
    input  logic        rst_n,
    // crossing (already isolated)
    input  logic        x_req,      // asynchronous
    input  logic [31:0] x_addr,
    input  logic [31:0] x_wdata,
    input  logic [3:0]  x_wstrb,
    output logic        x_ack,
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
    typedef enum logic [1:0] {A_IDLE, A_ACCESS, A_WAIT_NREQ} ast_t;
    ast_t st;
    logic req_s;

    tc_sync u_sync_req (.clk(clk), .rst_n(rst_n), .d(x_req), .q(req_s));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= A_IDLE;
            x_ack   <= 1'b0;
            x_rdata <= '0;
            m_addr  <= '0;
            m_wdata <= '0;
            m_wstrb <= '0;
        end else begin
            unique case (st)
                A_IDLE: if (req_s) begin
                    // bundled data has been stable for >= 2 clk_aon cycles
                    m_addr  <= x_addr;
                    m_wdata <= x_wdata;
                    m_wstrb <= x_wstrb;
                    st      <= A_ACCESS;
                end
                A_ACCESS: if (m_ready) begin
                    x_rdata <= m_rdata;
                    x_ack   <= 1'b1;
                    st      <= A_WAIT_NREQ;
                end
                A_WAIT_NREQ: if (!req_s) begin
                    x_ack <= 1'b0;
                    st    <= A_IDLE;
                end
                default: st <= A_IDLE;
            endcase
        end
    end
    assign m_valid = (st == A_ACCESS);
    assign idle    = (st == A_IDLE) && !req_s;
endmodule
