// Interrupt controller (PD_AON): 8 level-sensitive sources -> one machine
// external interrupt (MEIP).
//
//   0x00 PENDING   RO  raw source levels | software-set bits
//   0x04 ENABLE    RW
//   0x08 SOFT      R: software-set bits.  W: set bits (1 = set)
//   0x0C SOFT_CLR  W: clear software-set bits (1 = clear)
//   0x10 CLAIM     RO  1 + index of lowest pending & enabled source, 0 = none
//   0x14 RAW       RO  raw source levels
// Source map: 0 UART, 1 PMU, 2..7 unused (software-triggerable only).
module aon_intc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req,
    input  logic        we,
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [11:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [31:0] wdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] rdata,
    input  logic [7:0]  src,
    output logic        meip
);
    logic [7:0] en, swpend, src_q;
    wire  [7:0] pend = src_q | swpend;
    wire  [7:0] act  = pend & en;
    logic [3:0] claim;

    always_comb begin
        claim = 4'd0;
        for (int i = 7; i >= 0; i--) if (act[i]) claim = 4'(i + 1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en <= '0; swpend <= '0; src_q <= '0; rdata <= '0; meip <= 1'b0;
        end else begin
            src_q <= src;
            meip  <= |act;
            if (req && we) begin
                unique case (addr[4:2])
                    3'd1: en   <= wdata[7:0];
                    3'd2: swpend <= swpend | wdata[7:0];
                    3'd3: swpend <= swpend & ~wdata[7:0];
                    default: ;
                endcase
            end
            if (req && !we) begin
                unique case (addr[4:2])
                    3'd0: rdata <= {24'd0, pend};
                    3'd1: rdata <= {24'd0, en};
                    3'd2: rdata <= {24'd0, swpend};
                    3'd4: rdata <= {28'd0, claim};
                    3'd5: rdata <= {24'd0, src_q};
                    default: rdata <= '0;
                endcase
            end
        end
    end
endmodule
