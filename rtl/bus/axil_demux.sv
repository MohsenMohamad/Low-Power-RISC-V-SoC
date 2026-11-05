// -----------------------------------------------------------------------------
// axil_demux - AXI4-Lite 1-to-N interconnect (address decoder)
//
// One write and one read transaction in flight at a time (sufficient for the
// single in-order CPU master). Slave i is selected when
// (addr & MASK[i]) == BASE[i]; unmapped addresses get an UNMAPPED_RESP response (SLVERR by default, doc/SPEC.md) from
// the internal error slave.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module axil_demux #(
  parameter int              N    = 2,
  parameter logic [N*32-1:0] BASE = '0,
  parameter logic [N*32-1:0] MASK = '0,
  parameter logic [1:0]      UNMAPPED_RESP = 2'b10   // SLVERR (doc/SPEC.md: unmapped -> SLVERR)
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  // slave port (from master)
  input  logic          s_awvalid_i,
  output logic          s_awready_o,
  input  logic [31:0]   s_awaddr_i,
  input  logic [2:0]    s_awprot_i,
  input  logic          s_wvalid_i,
  output logic          s_wready_o,
  input  logic [31:0]   s_wdata_i,
  input  logic [3:0]    s_wstrb_i,
  output logic          s_bvalid_o,
  input  logic          s_bready_i,
  output logic [1:0]    s_bresp_o,
  input  logic          s_arvalid_i,
  output logic          s_arready_o,
  input  logic [31:0]   s_araddr_i,
  input  logic [2:0]    s_arprot_i,
  output logic          s_rvalid_o,
  input  logic          s_rready_i,
  output logic [31:0]   s_rdata_o,
  output logic [1:0]    s_rresp_o,
  // master ports (to slaves), signals shared except valids/readys
  output logic [N-1:0]  m_awvalid_o,
  input  logic [N-1:0]  m_awready_i,
  output logic [31:0]   m_awaddr_o,
  output logic [2:0]    m_awprot_o,
  output logic [N-1:0]  m_wvalid_o,
  input  logic [N-1:0]  m_wready_i,
  output logic [31:0]   m_wdata_o,
  output logic [3:0]    m_wstrb_o,
  input  logic [N-1:0]  m_bvalid_i,
  output logic [N-1:0]  m_bready_o,
  input  logic [N*2-1:0] m_bresp_i,
  output logic [N-1:0]  m_arvalid_o,
  input  logic [N-1:0]  m_arready_i,
  output logic [31:0]   m_araddr_o,
  output logic [2:0]    m_arprot_o,
  input  logic [N-1:0]  m_rvalid_i,
  output logic [N-1:0]  m_rready_o,
  input  logic [N*32-1:0] m_rdata_i,
  input  logic [N*2-1:0]  m_rresp_i
);
  localparam logic [1:0] RESP_UNMAPPED = UNMAPPED_RESP;

  function automatic logic [N:0] decode(input logic [31:0] addr);
    logic [N:0] sel;
    sel = '0;
    for (int i = 0; i < N; i++)
      if ((addr & MASK[32*i +: 32]) == BASE[32*i +: 32]) sel[i] = 1'b1;
    if (sel[N-1:0] == '0) sel[N] = 1'b1;  // error slave
    return sel;
  endfunction

  // ======================= write path =======================
  typedef enum logic [1:0] {W_IDLE, W_ISSUE, W_RESP} wstate_e;
  wstate_e     wstate_q;
  logic [N:0]  wsel_q;
  logic        aw_have_q, w_have_q;
  logic        aw_done_q, w_done_q;
  logic [31:0] awaddr_q, wdata_q;
  logic [2:0]  awprot_q;
  logic [3:0]  wstrb_q;
  logic [1:0]  bresp_q;
  logic        bvalid_q;

  assign s_awready_o = (wstate_q == W_IDLE) && !aw_have_q;
  assign s_wready_o  = (wstate_q == W_IDLE) && !w_have_q;

  assign m_awaddr_o = awaddr_q;
  assign m_awprot_o = awprot_q;
  assign m_wdata_o  = wdata_q;
  assign m_wstrb_o  = wstrb_q;

  always_comb begin
    m_awvalid_o = '0;
    m_wvalid_o  = '0;
    m_bready_o  = '0;
    if (wstate_q == W_ISSUE) begin
      m_awvalid_o = wsel_q[N-1:0] & {N{!aw_done_q}};
      m_wvalid_o  = wsel_q[N-1:0] & {N{!w_done_q}};
    end
    if (wstate_q == W_RESP && !bvalid_q) m_bready_o = wsel_q[N-1:0];
  end

  assign s_bvalid_o = bvalid_q;
  assign s_bresp_o  = bresp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wstate_q  <= W_IDLE;
      wsel_q    <= '0;
      aw_have_q <= 1'b0;
      w_have_q  <= 1'b0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      awaddr_q  <= '0;
      awprot_q  <= '0;
      wdata_q   <= '0;
      wstrb_q   <= '0;
      bresp_q   <= '0;
      bvalid_q  <= 1'b0;
    end else begin
      case (wstate_q)
        W_IDLE: begin
          if (s_awvalid_i && s_awready_o) begin
            aw_have_q <= 1'b1;
            awaddr_q  <= s_awaddr_i;
            awprot_q  <= s_awprot_i;
          end
          if (s_wvalid_i && s_wready_o) begin
            w_have_q <= 1'b1;
            wdata_q  <= s_wdata_i;
            wstrb_q  <= s_wstrb_i;
          end
          if ((aw_have_q || (s_awvalid_i && s_awready_o)) &&
              (w_have_q  || (s_wvalid_i  && s_wready_o))) begin
            wsel_q    <= decode(aw_have_q ? awaddr_q : s_awaddr_i);
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            wstate_q  <= W_ISSUE;
          end
        end
        W_ISSUE: begin
          if (wsel_q[N]) begin
            bresp_q  <= RESP_UNMAPPED;
            bvalid_q <= 1'b1;
            wstate_q <= W_RESP;
          end else begin
            if (|(m_awvalid_o & m_awready_i)) aw_done_q <= 1'b1;
            if (|(m_wvalid_o  & m_wready_i))  w_done_q  <= 1'b1;
            if ((aw_done_q || |(m_awvalid_o & m_awready_i)) &&
                (w_done_q  || |(m_wvalid_o  & m_wready_i)))
              wstate_q <= W_RESP;
          end
        end
        W_RESP: begin
          if (!bvalid_q) begin
            for (int i = 0; i < N; i++) begin
              if (wsel_q[i] && m_bvalid_i[i]) begin
                bresp_q  <= m_bresp_i[2*i +: 2];
                bvalid_q <= 1'b1;
              end
            end
          end else if (s_bready_i) begin
            bvalid_q  <= 1'b0;
            aw_have_q <= 1'b0;
            w_have_q  <= 1'b0;
            wstate_q  <= W_IDLE;
          end
        end
        default: wstate_q <= W_IDLE;
      endcase
    end
  end

  // ======================= read path =======================
  typedef enum logic [1:0] {R_IDLE, R_ISSUE, R_RESP} rstate_e;
  rstate_e     rstate_q;
  logic [N:0]  rsel_q;
  logic [31:0] araddr_q, rdata_q;
  logic [2:0]  arprot_q;
  logic [1:0]  rresp_q;
  logic        rvalid_q;

  assign s_arready_o = (rstate_q == R_IDLE);
  assign m_araddr_o  = araddr_q;
  assign m_arprot_o  = arprot_q;
  assign s_rvalid_o  = rvalid_q;
  assign s_rdata_o   = rdata_q;
  assign s_rresp_o   = rresp_q;

  always_comb begin
    m_arvalid_o = '0;
    m_rready_o  = '0;
    if (rstate_q == R_ISSUE) m_arvalid_o = rsel_q[N-1:0];
    if (rstate_q == R_RESP && !rvalid_q) m_rready_o = rsel_q[N-1:0];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rstate_q <= R_IDLE;
      rsel_q   <= '0;
      araddr_q <= '0;
      arprot_q <= '0;
      rdata_q  <= '0;
      rresp_q  <= '0;
      rvalid_q <= 1'b0;
    end else begin
      case (rstate_q)
        R_IDLE: begin
          if (s_arvalid_i) begin
            araddr_q <= s_araddr_i;
            arprot_q <= s_arprot_i;
            rsel_q   <= decode(s_araddr_i);
            rstate_q <= R_ISSUE;
          end
        end
        R_ISSUE: begin
          if (rsel_q[N]) begin
            rdata_q  <= '0;
            rresp_q  <= RESP_UNMAPPED;
            rvalid_q <= 1'b1;
            rstate_q <= R_RESP;
          end else if (|(m_arvalid_o & m_arready_i)) begin
            rstate_q <= R_RESP;
          end
        end
        R_RESP: begin
          if (!rvalid_q) begin
            for (int i = 0; i < N; i++) begin
              if (rsel_q[i] && m_rvalid_i[i]) begin
                rdata_q  <= m_rdata_i[32*i +: 32];
                rresp_q  <= m_rresp_i[2*i +: 2];
                rvalid_q <= 1'b1;
              end
            end
          end else if (s_rready_i) begin
            rvalid_q <= 1'b0;
            rstate_q <= R_IDLE;
          end
        end
        default: rstate_q <= R_IDLE;
      endcase
    end
  end

  `SVA_ASSERT(a_wsel_onehot, clk_i, rst_ni, (wstate_q == W_IDLE) || $onehot(wsel_q))
  `SVA_ASSERT(a_rsel_onehot, clk_i, rst_ni, (rstate_q == R_IDLE) || $onehot(rsel_q))
  `SVA_ASSERT_NXT(a_bvalid_stable, clk_i, rst_ni, s_bvalid_o && !s_bready_i, s_bvalid_o)
  `SVA_ASSERT_NXT(a_rvalid_stable, clk_i, rst_ni, s_rvalid_o && !s_rready_i, s_rvalid_o && $stable(s_rdata_o))
endmodule
