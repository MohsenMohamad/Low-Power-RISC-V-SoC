// Machine timer / wake timer (PD_AON), CLINT-compatible register layout.
//
//   0x0000 MSIP        [0] machine software interrupt
//   0x4000 MTIMECMP    low word,  0x4004 high word (reset: all ones)
//   0x8000 PRESCALE    mtime increments every PRESCALE+1 clk_aon cycles
//   0xBFF8 MTIME       low word,  0xBFFC high word
module aon_timer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req,
    input  logic        we,
    /* verilator lint_off UNUSEDSIGNAL */ // not all bus bits are decoded
    input  logic [15:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        mtip,
    output logic        msip
);
    logic [63:0] mtime, mtimecmp;
    logic [15:0] presc, pcnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime <= '0; mtimecmp <= '1; presc <= '0; pcnt <= '0;
            msip <= 1'b0; rdata <= '0; mtip <= 1'b0;
        end else begin
            if (pcnt == presc) begin
                pcnt  <= '0;
                mtime <= mtime + 1'b1;
            end else pcnt <= pcnt + 1'b1;
            mtip <= (mtime >= mtimecmp);

            if (req && we) begin
                unique case (addr[15:2])
                    14'h0000: msip <= wdata[0];
                    14'h1000: mtimecmp[31:0]  <= wdata;
                    14'h1001: mtimecmp[63:32] <= wdata;
                    14'h2000: presc <= wdata[15:0];
                    14'h2FFE: mtime[31:0]  <= wdata;
                    14'h2FFF: mtime[63:32] <= wdata;
                    default: ;
                endcase
            end
            if (req && !we) begin
                unique case (addr[15:2])
                    14'h0000: rdata <= {31'd0, msip};
                    14'h1000: rdata <= mtimecmp[31:0];
                    14'h1001: rdata <= mtimecmp[63:32];
                    14'h2000: rdata <= {16'd0, presc};
                    14'h2FFE: rdata <= mtime[31:0];
                    14'h2FFF: rdata <= mtime[63:32];
                    default:  rdata <= '0;
                endcase
            end
        end
    end
endmodule
