// 2:1 AXI4-Lite master multiplexer (first stage of the CPU-side interconnect).
//
// Read and write paths are arbitrated independently. Each path carries at most
// one transaction at a time: the owner is chosen (round-robin) one cycle after
// a request appears, then locked until the response handshake completes, so
// address/data presented downstream never change while VALID is high.
module axil_mux2 (
  input  logic        clk,
  input  logic        rst_n,

  // Slave ports (from masters) [0] and [1]
  input  logic [1:0]       s_awvalid,
  output logic [1:0]       s_awready,
  input  logic [1:0][31:0] s_awaddr,
  input  logic [1:0][2:0]  s_awprot,
  input  logic [1:0]       s_wvalid,
  output logic [1:0]       s_wready,
  input  logic [1:0][31:0] s_wdata,
  input  logic [1:0][3:0]  s_wstrb,
  output logic [1:0]       s_bvalid,
  input  logic [1:0]       s_bready,
  output logic [1:0][1:0]  s_bresp,
  input  logic [1:0]       s_arvalid,
  output logic [1:0]       s_arready,
  input  logic [1:0][31:0] s_araddr,
  input  logic [1:0][2:0]  s_arprot,
  output logic [1:0]       s_rvalid,
  input  logic [1:0]       s_rready,
  output logic [1:0][31:0] s_rdata,
  output logic [1:0][1:0]  s_rresp,

  // Master port (to interconnect / slave)
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_awaddr,
  output logic [2:0]  m_awprot,
  output logic        m_wvalid,
  input  logic        m_wready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_bvalid,
  output logic        m_bready,
  input  logic [1:0]  m_bresp,
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [2:0]  m_arprot,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,

  output logic        idle_o      // no transaction owned on either path
);

  typedef enum logic [1:0] { P_IDLE, P_ADDR, P_RESP } path_e;

  // ---------------------------------------------------------------------------
  // Read path
  // ---------------------------------------------------------------------------
  path_e rd_q;
  logic  rd_own_q, rd_last_q;
  logic  rd_pick;

  // Round-robin: prefer the master that was not served last.
  assign rd_pick = (s_arvalid[0] && s_arvalid[1]) ? !rd_last_q : s_arvalid[1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_q <= P_IDLE; rd_own_q <= 1'b0; rd_last_q <= 1'b1;
    end else begin
      unique case (rd_q)
        P_IDLE: if (|s_arvalid) begin rd_own_q <= rd_pick; rd_q <= P_ADDR; end
        P_ADDR: if (m_arready) rd_q <= P_RESP;
        P_RESP: if (m_rvalid && s_rready[rd_own_q]) begin rd_q <= P_IDLE; rd_last_q <= rd_own_q; end
        default: rd_q <= P_IDLE;
      endcase
    end
  end

  always_comb begin
    m_arvalid = (rd_q == P_ADDR) && s_arvalid[rd_own_q];
    m_araddr  = s_araddr[rd_own_q];
    m_arprot  = s_arprot[rd_own_q];
    m_rready  = (rd_q == P_RESP) && s_rready[rd_own_q];
    s_arready = '0;
    s_rvalid  = '0;
    s_arready[rd_own_q] = (rd_q == P_ADDR) && m_arready;
    s_rvalid[rd_own_q]  = (rd_q == P_RESP) && m_rvalid;
    for (int i = 0; i < 2; i++) begin
      s_rdata[i] = m_rdata;
      s_rresp[i] = m_rresp;
    end
  end

  // ---------------------------------------------------------------------------
  // Write path
  // ---------------------------------------------------------------------------
  path_e wr_q;
  logic  wr_own_q, wr_last_q;
  logic  aw_done_q, w_done_q;
  logic  wr_pick;
  logic [1:0] wr_req;

  assign wr_req  = s_awvalid | s_wvalid;
  assign wr_pick = (wr_req[0] && wr_req[1]) ? !wr_last_q : wr_req[1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_q <= P_IDLE; wr_own_q <= 1'b0; wr_last_q <= 1'b1;
      aw_done_q <= 1'b0; w_done_q <= 1'b0;
    end else begin
      unique case (wr_q)
        P_IDLE: if (|wr_req) begin
          wr_own_q <= wr_pick; wr_q <= P_ADDR; aw_done_q <= 1'b0; w_done_q <= 1'b0;
        end
        P_ADDR: begin
          if (m_awvalid && m_awready) aw_done_q <= 1'b1;
          if (m_wvalid && m_wready)   w_done_q  <= 1'b1;
          if ((aw_done_q || (m_awvalid && m_awready)) && (w_done_q || (m_wvalid && m_wready)))
            wr_q <= P_RESP;
        end
        P_RESP: if (m_bvalid && s_bready[wr_own_q]) begin wr_q <= P_IDLE; wr_last_q <= wr_own_q; end
        default: wr_q <= P_IDLE;
      endcase
    end
  end

  always_comb begin
    m_awvalid = (wr_q == P_ADDR) && !aw_done_q && s_awvalid[wr_own_q];
    m_awaddr  = s_awaddr[wr_own_q];
    m_awprot  = s_awprot[wr_own_q];
    m_wvalid  = (wr_q == P_ADDR) && !w_done_q && s_wvalid[wr_own_q];
    m_wdata   = s_wdata[wr_own_q];
    m_wstrb   = s_wstrb[wr_own_q];
    m_bready  = (wr_q == P_RESP) && s_bready[wr_own_q];
    s_awready = '0;
    s_wready  = '0;
    s_bvalid  = '0;
    s_awready[wr_own_q] = (wr_q == P_ADDR) && !aw_done_q && m_awready;
    s_wready[wr_own_q]  = (wr_q == P_ADDR) && !w_done_q && m_wready;
    s_bvalid[wr_own_q]  = (wr_q == P_RESP) && m_bvalid;
    for (int i = 0; i < 2; i++) s_bresp[i] = m_bresp;
  end

  assign idle_o = (rd_q == P_IDLE) && (wr_q == P_IDLE);

endmodule
