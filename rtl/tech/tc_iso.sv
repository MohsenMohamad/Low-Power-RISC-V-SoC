// Technology wrapper: isolation cell (clamp to constant), generic model.
module tc_iso #(
    parameter int unsigned W = 1,
    parameter logic [W-1:0] CLAMP = '0
) (
    input  logic         iso_en,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
    assign q = iso_en ? CLAMP : d;
endmodule
