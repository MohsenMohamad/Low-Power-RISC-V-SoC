// Technology wrapper: reset synchronizer, asynchronous assert,
// synchronous de-assert (generic model).
module tc_rst_sync #(
    parameter int unsigned STAGES = 2
) (
    input  logic clk,
    input  logic rst_n_in,
    output logic rst_n_out
);
    logic [STAGES-1:0] ff;
    always_ff @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) ff <= '0;
        else           ff <= {ff[STAGES-2:0], 1'b1};
    end
    assign rst_n_out = ff[STAGES-1];
endmodule
