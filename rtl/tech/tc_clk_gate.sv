// Technology wrapper: integrated clock gate (latch-based, generic model).
// 'en' must be synchronous to 'clk'.
module tc_clk_gate (
    input  logic clk,
    input  logic en,
    input  logic test_en,
    output logic gclk
);
    logic en_lat;
    /* verilator lint_off LATCH */
    always_latch begin
        if (!clk) en_lat = en | test_en;
    end
    /* verilator lint_on LATCH */
    assign gclk = clk & en_lat;
endmodule
