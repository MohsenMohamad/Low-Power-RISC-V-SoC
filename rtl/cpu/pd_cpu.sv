// -----------------------------------------------------------------------------
// pd_cpu - PD_CPU power-domain boundary (switchable, clk_cpu)
//
// Everything instantiated below this module belongs to PD_CPU in the UPF
// (create_power_domain PD_CPU -elements {u_pd_cpu}). All outputs are isolated
// in the parent (PD_AON) by tech_iso cells; inputs need no isolation.
// Caches will be added here together with the in-house core.
// -----------------------------------------------------------------------------
module pd_cpu (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        meip_i,
  input  logic        mtip_i,
  input  logic        msip_i,
  input  logic        idle_req_i,
  output wire         idle_ack_o,
  output wire         core_sleep_o,
  output wire         cache_clean_o,
  output wire         trap_o,
  output wire         m_awvalid_o,
  input  logic        m_awready_i,
  output wire  [31:0] m_awaddr_o,
  output wire  [2:0]  m_awprot_o,
  output wire         m_wvalid_o,
  input  logic        m_wready_i,
  output wire  [31:0] m_wdata_o,
  output wire  [3:0]  m_wstrb_o,
  input  logic        m_bvalid_i,
  output wire         m_bready_o,
  input  logic [1:0]  m_bresp_i,
  output wire         m_arvalid_o,
  input  logic        m_arready_i,
  output wire  [31:0] m_araddr_o,
  output wire  [2:0]  m_arprot_o,
  input  logic        m_rvalid_i,
  output wire         m_rready_o,
  input  logic [31:0] m_rdata_i,
  input  logic [1:0]  m_rresp_i
);
  cpu_core_picorv32 u_core (.*);
endmodule
