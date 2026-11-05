// Technology wrapper: N-input glitch-free clock multiplexer (generic model).
//
// Classic structure: every input clock has an enable synchronizer clocked on
// the falling edge of that clock. An input is enabled only after all other
// inputs have been disabled, so the output never glitches. 'sel' may change
// asynchronously. 'active' (one-hot, per input clock domain) shows which
// input currently drives the output; synchronize it before use.
module tc_clk_mux_gf #(
    parameter int unsigned N = 3
) (
    input  logic [N-1:0]         clk_in,
    input  logic                 rst_n,      // asynchronous
    input  logic [$clog2(N)-1:0] sel,
    output logic                 clk_out,
    output logic [N-1:0]         active
);
    logic [N-1:0] en_q;

    for (genvar i = 0; i < N; i++) begin : g_in
        logic others_off;
        logic want;
        logic s1, en;
        always_comb begin
            others_off = 1'b1;
            for (int j = 0; j < N; j++)
                if (j != i && en_q[j]) others_off = 1'b0;
        end
        assign want = (sel == i[$clog2(N)-1:0]) && others_off;
        // Input 0 is the default clock after reset.
        always_ff @(negedge clk_in[i] or negedge rst_n) begin
            if (!rst_n) begin
                s1 <= (i == 0);
                en <= (i == 0);
            end else begin
                s1 <= want;
                en <= s1;
            end
        end
        assign en_q[i] = en;
    end

    always_comb begin
        clk_out = 1'b0;
        for (int i = 0; i < N; i++) clk_out = clk_out | (clk_in[i] & en_q[i]);
    end
    assign active = en_q;
endmodule
