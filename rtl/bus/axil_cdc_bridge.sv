// -----------------------------------------------------------------------------
// axil_cdc_bridge - AXI4-Lite clock-domain-crossing bridge
//
// Slave port on clk_s (CPU clock), master port on clk_m (always-on clock).
// Each of the five AXI channels crosses through its own cdc_async_fifo.
//
// The bridge is placed in PD_AON (it is never powered down); its slave-side
// flops are clocked by the gated CPU clock and are reset only by the system
// power-on reset, so FIFO pointers stay coherent across CPU power cycles as
// long as the bridge is idle when the CPU domain is switched off.
//
// idle_m_o (clk_m domain) is high when no transaction is in flight anywhere in
// the bridge: all FIFOs are empty (as seen from clk_m), the master side has no
// outstanding requests and the slave side (synchronized) reports no
// outstanding requests. The PMU requires it before isolating the CPU.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module axil_cdc_bridge #(
  parameter int DEPTH = 4
) (
  // slave side (clk_s)
  input  logic        clk_s_i,
  input  logic        rst_s_ni,
  input  logic        s_awvalid_i,
  output logic        s_awready_o,
  input  logic [31:0] s_awaddr_i,
  input  logic [2:0]  s_awprot_i,
  input  logic        s_wvalid_i,
  output logic        s_wready_o,
  input  logic [31:0] s_wdata_i,
  input  logic [3:0]  s_wstrb_i,
  output logic        s_bvalid_o,
  input  logic        s_bready_i,
  output logic [1:0]  s_bresp_o,
  input  logic        s_arvalid_i,
  output logic        s_arready_o,
  input  logic [31:0] s_araddr_i,
  input  logic [2:0]  s_arprot_i,
  output logic        s_rvalid_o,
  input  logic        s_rready_i,
  output logic [31:0] s_rdata_o,
  output logic [1:0]  s_rresp_o,
  // master side (clk_m)
  input  logic        clk_m_i,
  input  logic        rst_m_ni,
  output logic        m_awvalid_o,
  input  logic        m_awready_i,
  output logic [31:0] m_awaddr_o,
  output logic [2:0]  m_awprot_o,
  output logic        m_wvalid_o,
  input  logic        m_wready_i,
  output logic [31:0] m_wdata_o,
  output logic [3:0]  m_wstrb_o,
  input  logic        m_bvalid_i,
  output logic        m_bready_o,
  input  logic [1:0]  m_bresp_i,
  output logic        m_arvalid_o,
  input  logic        m_arready_i,
  output logic [31:0] m_araddr_o,
  output logic [2:0]  m_arprot_o,
  input  logic        m_rvalid_i,
  output logic        m_rready_o,
  input  logic [31:0] m_rdata_i,
  input  logic [1:0]  m_rresp_i,
  output logic        idle_m_o
);
  logic aw_wempty, w_wempty, ar_wempty, b_wempty, r_wempty;

  cdc_async_fifo #(.WIDTH(35), .DEPTH(DEPTH)) u_aw (
    .wclk_i (clk_s_i), .wrst_ni (rst_s_ni), .wvalid_i (s_awvalid_i), .wready_o (s_awready_o),
    .wdata_i ({s_awprot_i, s_awaddr_i}), .w_empty_o (aw_wempty),
    .rclk_i (clk_m_i), .rrst_ni (rst_m_ni), .rvalid_o (m_awvalid_o), .rready_i (m_awready_i),
    .rdata_o ({m_awprot_o, m_awaddr_o})
  );
  cdc_async_fifo #(.WIDTH(36), .DEPTH(DEPTH)) u_w (
    .wclk_i (clk_s_i), .wrst_ni (rst_s_ni), .wvalid_i (s_wvalid_i), .wready_o (s_wready_o),
    .wdata_i ({s_wstrb_i, s_wdata_i}), .w_empty_o (w_wempty),
    .rclk_i (clk_m_i), .rrst_ni (rst_m_ni), .rvalid_o (m_wvalid_o), .rready_i (m_wready_i),
    .rdata_o ({m_wstrb_o, m_wdata_o})
  );
  cdc_async_fifo #(.WIDTH(35), .DEPTH(DEPTH)) u_ar (
    .wclk_i (clk_s_i), .wrst_ni (rst_s_ni), .wvalid_i (s_arvalid_i), .wready_o (s_arready_o),
    .wdata_i ({s_arprot_i, s_araddr_i}), .w_empty_o (ar_wempty),
    .rclk_i (clk_m_i), .rrst_ni (rst_m_ni), .rvalid_o (m_arvalid_o), .rready_i (m_arready_i),
    .rdata_o ({m_arprot_o, m_araddr_o})
  );
  cdc_async_fifo #(.WIDTH(2), .DEPTH(DEPTH)) u_b (
    .wclk_i (clk_m_i), .wrst_ni (rst_m_ni), .wvalid_i (m_bvalid_i), .wready_o (m_bready_o),
    .wdata_i (m_bresp_i), .w_empty_o (b_wempty),
    .rclk_i (clk_s_i), .rrst_ni (rst_s_ni), .rvalid_o (s_bvalid_o), .rready_i (s_bready_i),
    .rdata_o (s_bresp_o)
  );
  cdc_async_fifo #(.WIDTH(34), .DEPTH(DEPTH)) u_r (
    .wclk_i (clk_m_i), .wrst_ni (rst_m_ni), .wvalid_i (m_rvalid_i), .wready_o (m_rready_o),
    .wdata_i ({m_rresp_i, m_rdata_i}), .w_empty_o (r_wempty),
    .rclk_i (clk_s_i), .rrst_ni (rst_s_ni), .rvalid_o (s_rvalid_o), .rready_i (s_rready_i),
    .rdata_o ({s_rresp_o, s_rdata_o})
  );

  // ---------------- outstanding tracking, slave side ----------------
  // Writes are counted by AW handshakes; reads by AR handshakes.
  logic [3:0] s_wr_out_q, s_rd_out_q;
  logic       s_idle_q, s_idle_msync;
  always_ff @(posedge clk_s_i or negedge rst_s_ni) begin
    if (!rst_s_ni) begin
      s_wr_out_q <= '0;
      s_rd_out_q <= '0;
      s_idle_q   <= 1'b1;
    end else begin
      s_wr_out_q <= s_wr_out_q + 4'(s_awvalid_i && s_awready_o) - 4'(s_bvalid_o && s_bready_i);
      s_rd_out_q <= s_rd_out_q + 4'(s_arvalid_i && s_arready_o) - 4'(s_rvalid_o && s_rready_i);
      // Registered so the synchronizer sees a glitch-free level.
      s_idle_q   <= (s_wr_out_q + 4'(s_awvalid_i && s_awready_o) - 4'(s_bvalid_o && s_bready_i) == 0) &&
                    (s_rd_out_q + 4'(s_arvalid_i && s_arready_o) - 4'(s_rvalid_o && s_rready_i) == 0) &&
                    !s_wvalid_i;
    end
  end

  tech_sync #(.WIDTH(1), .STAGES(2), .RESET_VAL(1'b1)) u_sync_sidle (
    .clk_i (clk_m_i), .rst_ni (rst_m_ni), .d_i (s_idle_q), .q_o (s_idle_msync)
  );

  // ---------------- outstanding tracking, master side ----------------
  logic [3:0] m_wr_out_q, m_rd_out_q;
  always_ff @(posedge clk_m_i or negedge rst_m_ni) begin
    if (!rst_m_ni) begin
      m_wr_out_q <= '0;
      m_rd_out_q <= '0;
    end else begin
      m_wr_out_q <= m_wr_out_q + 4'(m_awvalid_o && m_awready_i) - 4'(m_bvalid_i && m_bready_o);
      m_rd_out_q <= m_rd_out_q + 4'(m_arvalid_o && m_arready_i) - 4'(m_rvalid_i && m_rready_o);
    end
  end

  assign idle_m_o = s_idle_msync && (m_wr_out_q == 0) && (m_rd_out_q == 0) &&
                    !m_awvalid_o && !m_wvalid_o && !m_arvalid_o && b_wempty && r_wempty;

  // Writer-side empty flags of the request FIFOs are not needed: the slave
  // side tracks its own outstanding requests.
  logic unused;
  assign unused = ^{aw_wempty, w_wempty, ar_wempty};

  `SVA_ASSERT(a_s_wr_out_bound, clk_s_i, rst_s_ni, s_wr_out_q <= 4'(2*DEPTH+2))
  `SVA_ASSERT(a_s_rd_out_bound, clk_s_i, rst_s_ni, s_rd_out_q <= 4'(2*DEPTH+2))
endmodule
