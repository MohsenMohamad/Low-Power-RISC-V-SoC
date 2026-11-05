// -----------------------------------------------------------------------------
// cpu_clk_rst_ctrl - PD_CPU clock gate and reset generation (lives in PD_AON)
//
//   * cg_en (clk_aon, from PMU) -> synchronized into clk_cpu_root -> ICG.
//     The synchronized enable is returned to clk_aon as cg_ack.
//   * CPU reset: asynchronous assert from POR or PMU, de-assert synchronized
//     to clk_cpu_root (free-running DVFS clock, so the release does not need
//     the gated clock). The released state is returned to clk_aon.
//   * Bridge reset: POR only, synchronized to clk_cpu_root.
// -----------------------------------------------------------------------------
module cpu_clk_rst_ctrl (
  input  logic clk_cpu_root_i,
  input  logic clk_aon_i,
  input  logic por_ni,
  input  logic rst_aon_ni,
  input  logic test_en_i,
  input  logic cg_en_i,         // clk_aon
  output logic cg_ack_o,        // clk_aon
  input  logic cpu_rst_req_ni,  // clk_aon (PMU)
  output logic cpu_rst_ack_o,   // clk_aon, 1 = released
  output logic clk_cpu_o,
  output logic cpu_rst_no,
  output logic bridge_rst_no
);
  logic root_rst_n;
  logic cg_en_s;

  rst_sync u_root_rst (.clk_i (clk_cpu_root_i), .arst_ni (por_ni), .rst_no (root_rst_n));
  assign bridge_rst_no = root_rst_n;

  tech_sync #(.WIDTH(1), .STAGES(2), .RESET_VAL(1'b1)) u_cg_sync (
    .clk_i (clk_cpu_root_i), .rst_ni (root_rst_n), .d_i (cg_en_i), .q_o (cg_en_s)
  );

  tech_clk_gate u_cg (
    .clk_i (clk_cpu_root_i), .en_i (cg_en_s), .test_en_i (test_en_i), .clk_o (clk_cpu_o)
  );

  tech_sync #(.WIDTH(1), .STAGES(2), .RESET_VAL(1'b1)) u_cg_ack_sync (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_ni), .d_i (cg_en_s), .q_o (cg_ack_o)
  );

  rst_sync u_cpu_rst (
    .clk_i (clk_cpu_root_i), .arst_ni (por_ni & cpu_rst_req_ni), .rst_no (cpu_rst_no)
  );

  tech_sync #(.WIDTH(1), .STAGES(2), .RESET_VAL(1'b0)) u_rst_ack_sync (
    .clk_i (clk_aon_i), .rst_ni (rst_aon_ni), .d_i (cpu_rst_no), .q_o (cpu_rst_ack_o)
  );
endmodule
