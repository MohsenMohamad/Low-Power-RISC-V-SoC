// Technology wrapper: interface to the PD_CPU voltage regulator (generic
// model). 'vok' is low from the moment 'vsel' differs from the delivered
// level until the regulator has settled at the new level.
module tc_vreg #(
    parameter int unsigned SETTLE = 32
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [1:0] vsel,
    output logic [1:0] vlevel,
    output logic       vok
);
    logic [$clog2(SETTLE+1)-1:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vlevel <= 2'd2;
            cnt    <= '0;
        end else if (vsel != vlevel) begin
            if (cnt == ($clog2(SETTLE+1))'(SETTLE)) begin
                vlevel <= vsel;
                cnt    <= '0;
            end else cnt <= cnt + 1'b1;
        end else cnt <= '0;
    end
    assign vok = (vsel == vlevel);
endmodule
