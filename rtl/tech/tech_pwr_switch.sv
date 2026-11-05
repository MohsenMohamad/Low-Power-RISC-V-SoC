// -----------------------------------------------------------------------------
// tech_pwr_switch - power switch (header) chain wrapper
//
// Generic model of a daisy-chained power switch with an acknowledge output.
//   sw_en_i     : switch control from the PMU (1 = on)
//   pwr_good_o  : acknowledge from the end of the switch chain (rail settled)
//   supply_on_o : modelled state of the switched rail; low while the rail is
//                 off or still ramping. Used only by the simulation corruption
//                 model and by the FPGA emulation (reset hold). It carries no
//                 logic function in an ASIC implementation (the real rail is
//                 described in the UPF file).
// The ramp is modelled with a counter on the always-on reference clock so the
// model is synthesizable for FPGA emulation.
// -----------------------------------------------------------------------------
module tech_pwr_switch #(
  parameter int ON_DLY  = 8,  // reference cycles from sw_en rise to pwr_good
  parameter int OFF_DLY = 4   // reference cycles from sw_en fall to !pwr_good
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic sw_en_i,
  output logic pwr_good_o,
  output logic supply_on_o
);
  localparam int CW = $clog2((ON_DLY > OFF_DLY ? ON_DLY : OFF_DLY) + 1);
  logic [CW-1:0] cnt_q;
  logic          good_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_q  <= '0;
      good_q <= 1'b1;  // domain powered at power-on reset
    end else if (sw_en_i != good_q) begin
      if (sw_en_i ? (cnt_q == CW'(ON_DLY - 1)) : (cnt_q == CW'(OFF_DLY - 1))) begin
        good_q <= sw_en_i;
        cnt_q  <= '0;
      end else begin
        cnt_q  <= cnt_q + 1'b1;
      end
    end else begin
      cnt_q <= '0;
    end
  end

  assign pwr_good_o  = good_q;
  assign supply_on_o = good_q & sw_en_i;
endmodule
