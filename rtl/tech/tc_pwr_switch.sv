// Technology wrapper: power switch for a switchable domain (generic model).
//
// 'en' turns the header switches on. 'pgood' rises RAMP_ON control-clock
// cycles after 'en' rises and falls RAMP_OFF cycles after 'en' falls. 'pwr'
// models the actual rail state and is used only by simulation corruption
// models of the switched domain. A real implementation replaces this module
// with the switch cell chain plus the power-good detector.
module tc_pwr_switch #(
    parameter int unsigned RAMP_ON  = 16,
    parameter int unsigned RAMP_OFF = 4
) (
    input  logic clk,     // always-on control clock
    input  logic rst_n,
    input  logic en,
    output logic pgood,
    output logic pwr
);
    localparam int unsigned CW = $clog2((RAMP_ON > RAMP_OFF ? RAMP_ON : RAMP_OFF) + 1);
    logic [CW-1:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= '0;
            pgood <= 1'b0;
            pwr   <= 1'b0;
        end else if (en && !pgood) begin
            pwr <= 1'b1;
            if (cnt == CW'(RAMP_ON - 1)) begin
                pgood <= 1'b1;
                cnt   <= '0;
            end else cnt <= cnt + 1'b1;
        end else if (!en && pwr) begin
            pgood <= 1'b0;
            if (cnt == CW'(RAMP_OFF - 1)) begin
                pwr <= 1'b0;
                cnt <= '0;
            end else cnt <= cnt + 1'b1;
        end else cnt <= '0;
    end
endmodule
