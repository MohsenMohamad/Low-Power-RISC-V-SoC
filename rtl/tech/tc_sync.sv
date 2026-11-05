// Technology wrapper: N-flop bit synchronizer (generic model).
// Replace the body with the library synchronizer cell for ASIC/FPGA.
module tc_sync #(
    parameter int unsigned STAGES = 2,
    parameter bit          RESET_VAL = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic d,
    output logic q
);
    logic [STAGES-1:0] ff;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ff <= {STAGES{RESET_VAL}};
        else        ff <= {ff[STAGES-2:0], d};
    end
    assign q = ff[STAGES-1];
endmodule
