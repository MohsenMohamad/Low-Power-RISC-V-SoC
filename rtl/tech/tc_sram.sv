// Technology wrapper: single-port synchronous SRAM macro (generic model).
//
//  - 1-cycle read latency, byte write enables.
//  - pwr : array supply present. In simulation the contents are scrambled
//          when the supply goes away (OFF-state corruption model).
//  - ret : retention mode. Contents are kept, the macro must not be accessed;
//          an access in retention returns garbage and is reported.
module tc_sram #(
    parameter int unsigned DEPTH = 1024,
    parameter int unsigned W     = 32,
    parameter string       INIT_FILE = "",
    parameter string       INIT_PLUSARG = "",
    localparam int unsigned AW = $clog2(DEPTH),
    localparam int unsigned BW = (W + 7) / 8
) (
    input  logic          clk,
    input  logic          ce,
    input  logic          we,
    input  logic [BW-1:0] be,
    input  logic [AW-1:0] addr,
    input  logic [W-1:0]  wdata,
    output logic [W-1:0]  rdata,
    input  logic          pwr,
    input  logic          ret
);
    logic [W-1:0] mem [DEPTH];

    /* verilator lint_off MULTIDRIVEN */
    /* verilator lint_off BLKSEQ */
    always_ff @(posedge clk) begin
        if (ce) begin
            if (ret) begin
`ifndef SYNTHESIS
                $error("%m: access while in retention mode (addr=%0h)", addr);
                rdata <= W'($urandom);
`endif
            end else if (we) begin
                for (int b = 0; b < BW; b++)
                    if (be[b])
                        for (int k = 8*b; k < 8*b+8 && k < W; k++) mem[addr][k] <= wdata[k];
            end else begin
                rdata <= mem[addr];
            end
        end
    end

`ifndef SYNTHESIS
    // Simulation backdoor preload: INIT_FILE, or the file named by the
    // plusarg +<INIT_PLUSARG>=<file> (word-wide $readmemh format).
    initial begin
        string f;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
        if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, f))
            $readmemh(f, mem);
    end
    // OFF-state corruption model: losing supply destroys the contents.
    always @(negedge pwr) begin
        for (int i = 0; i < int'(DEPTH); i++) mem[i] = W'({$urandom, $urandom});
    end
`endif
    /* verilator lint_on BLKSEQ */
    /* verilator lint_on MULTIDRIVEN */
endmodule
