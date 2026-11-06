// Debug subsystem wrapper: one AXI4-Lite port (16 KB, addr[13:12] selects
// trace / evcnt / errlog / wdt), the four blocks and their internal wiring
// (doc/DEBUG_SPEC.md section 4.5). Optional: the SoC top may instantiate the
// four blocks directly on its own interconnect instead.
//
// The demux accepts a write only when AWVALID and WVALID are both high (AXI
// allows a slave to wait for both) and keeps one transaction per channel
// outstanding.
module dbg_subsys
  import dbg_pkg::*;
#(
  parameter int unsigned TRACE_DEPTH = 64
) (
  input  logic        clk_aon_i,
  input  logic        rst_aon_ni,
  input  logic        clk_cpu_i,
  // AXI4-Lite slave (clk_aon)
  input  logic [13:0] s_axil_awaddr,
  input  logic [2:0]  s_axil_awprot,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [13:0] s_axil_araddr,
  input  logic [2:0]  s_axil_arprot,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // CPU (clk_cpu)
  input  logic        ret_valid_i,
  input  logic [31:0] ret_pc_i,
  input  logic [31:0] ret_insn_i,
  input  logic        trap_valid_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_tval_i,
  input  logic        ic_hit_i,
  input  logic        ic_miss_i,
  input  logic        dc_hit_i,
  input  logic        dc_miss_i,
  input  logic        stall_i,
  // PMU (clk_aon)
  input  logic [1:0]  pwr_state_i,
  input  logic [1:0]  dvfs_op_i,
  input  logic        pmu_evt_valid_i,
  input  logic [1:0]  pmu_evt_from_i,
  input  logic [1:0]  pmu_evt_to_i,
  input  logic [1:0]  pmu_evt_result_i,
  // outputs (clk_aon)
  output logic        cpu_rst_req_o,
  output logic        wdt_irq_o,
  output logic        err_irq_o
);
  localparam int unsigned N = 4;
  logic [N-1:0]  awv, awr, wv, wr, bv, arv, arr, rv;
  logic [1:0]    bresp [N];
  logic [1:0]    rresp [N];
  logic [31:0]   rdata [N];

  wire [1:0] wsel = s_axil_awaddr[13:12];
  wire [1:0] rsel = s_axil_araddr[13:12];
  wire b_busy = |bv;
  wire r_busy = |rv;
  wire w_go   = s_axil_awvalid && s_axil_wvalid && !b_busy;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      awv[i] = w_go && wsel == 2'(i);
      wv[i]  = w_go && wsel == 2'(i);
      arv[i] = s_axil_arvalid && !r_busy && rsel == 2'(i);
    end
  end
  assign s_axil_awready = w_go && awr[wsel] && wr[wsel];
  assign s_axil_wready  = s_axil_awready;
  assign s_axil_arready = !r_busy && arr[rsel];

  always_comb begin
    s_axil_bvalid = 1'b0; s_axil_bresp = 2'b00;
    s_axil_rvalid = 1'b0; s_axil_rresp = 2'b00; s_axil_rdata = '0;
    for (int i = 0; i < N; i++) begin
      if (bv[i]) begin s_axil_bvalid = 1'b1; s_axil_bresp = bresp[i]; end
      if (rv[i]) begin s_axil_rvalid = 1'b1; s_axil_rresp = rresp[i]; s_axil_rdata = rdata[i]; end
    end
  end

  logic freeze, wdt_evt, wdt_ack, rst_req;
  assign cpu_rst_req_o = rst_req;

  dbg_trace #(.DEPTH(TRACE_DEPTH)) u_trace (
    .clk_aon_i, .rst_aon_ni, .clk_cpu_i,
    .s_axil_awaddr(s_axil_awaddr[11:0]), .s_axil_awprot, .s_axil_awvalid(awv[0]), .s_axil_awready(awr[0]),
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid(wv[0]), .s_axil_wready(wr[0]),
    .s_axil_bresp(bresp[0]), .s_axil_bvalid(bv[0]), .s_axil_bready,
    .s_axil_araddr(s_axil_araddr[11:0]), .s_axil_arprot, .s_axil_arvalid(arv[0]), .s_axil_arready(arr[0]),
    .s_axil_rdata(rdata[0]), .s_axil_rresp(rresp[0]), .s_axil_rvalid(rv[0]), .s_axil_rready,
    .ret_valid_i, .ret_pc_i, .ret_insn_i, .trap_valid_i, .trap_cause_i, .trap_pc_i, .trap_tval_i,
    .pwr_state_i, .freeze_i(freeze));

  dbg_evcnt u_evcnt (
    .clk_aon_i, .rst_aon_ni, .clk_cpu_i,
    .s_axil_awaddr(s_axil_awaddr[11:0]), .s_axil_awprot, .s_axil_awvalid(awv[1]), .s_axil_awready(awr[1]),
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid(wv[1]), .s_axil_wready(wr[1]),
    .s_axil_bresp(bresp[1]), .s_axil_bvalid(bv[1]), .s_axil_bready,
    .s_axil_araddr(s_axil_araddr[11:0]), .s_axil_arprot, .s_axil_arvalid(arv[1]), .s_axil_arready(arr[1]),
    .s_axil_rdata(rdata[1]), .s_axil_rresp(rresp[1]), .s_axil_rvalid(rv[1]), .s_axil_rready,
    .ic_hit_i, .ic_miss_i, .dc_hit_i, .dc_miss_i, .stall_i,
    .pwr_state_i, .dvfs_op_i, .freeze_i(freeze));

  dbg_errlog u_errlog (
    .clk_aon_i, .rst_aon_ni, .clk_cpu_i,
    .s_axil_awaddr(s_axil_awaddr[11:0]), .s_axil_awprot, .s_axil_awvalid(awv[2]), .s_axil_awready(awr[2]),
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid(wv[2]), .s_axil_wready(wr[2]),
    .s_axil_bresp(bresp[2]), .s_axil_bvalid(bv[2]), .s_axil_bready,
    .s_axil_araddr(s_axil_araddr[11:0]), .s_axil_arprot, .s_axil_arvalid(arv[2]), .s_axil_arready(arr[2]),
    .s_axil_rdata(rdata[2]), .s_axil_rresp(rresp[2]), .s_axil_rvalid(rv[2]), .s_axil_rready,
    .trap_valid_i, .trap_cause_i, .trap_pc_i, .trap_tval_i,
    .pwr_state_i, .pmu_evt_valid_i, .pmu_evt_from_i, .pmu_evt_to_i, .pmu_evt_result_i,
    .wdt_evt_i(wdt_evt), .wdt_evt_ack_o(wdt_ack), .wdt_rst_i(rst_req),
    .irq_o(err_irq_o), .freeze_o(freeze));

  dbg_wdt u_wdt (
    .clk_aon_i, .rst_aon_ni,
    .s_axil_awaddr(s_axil_awaddr[11:0]), .s_axil_awprot, .s_axil_awvalid(awv[3]), .s_axil_awready(awr[3]),
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid(wv[3]), .s_axil_wready(wr[3]),
    .s_axil_bresp(bresp[3]), .s_axil_bvalid(bv[3]), .s_axil_bready,
    .s_axil_araddr(s_axil_araddr[11:0]), .s_axil_arprot, .s_axil_arvalid(arv[3]), .s_axil_arready(arr[3]),
    .s_axil_rdata(rdata[3]), .s_axil_rresp(rresp[3]), .s_axil_rvalid(rv[3]), .s_axil_rready,
    .pwr_state_i, .wdt_evt_o(wdt_evt), .wdt_evt_ack_i(wdt_ack),
    .cpu_rst_req_o(rst_req), .irq_o(wdt_irq_o));
endmodule
