// -----------------------------------------------------------------------------
// axi_lite_if.sv - AXI4-Lite interface (32-bit address, 32-bit data)
//
// Reusable: carries no DUT-specific information. The master driver uses
// drv_cb, the passive monitor uses mon_cb. Protocol assertions live in
// axi_lite_protocol_checker.sv and are bound to this interface.
// -----------------------------------------------------------------------------
interface axi_lite_if (input logic aclk, input logic aresetn);

  logic [31:0] awaddr;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [31:0] araddr;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  clocking drv_cb @(posedge aclk);
    default input #1step output #1;
    output awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready,
           araddr, arprot, arvalid, rready;
    input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awaddr, awprot, awvalid, awready, wdata, wstrb, wvalid, wready,
          bresp, bvalid, bready, araddr, arprot, arvalid, arready,
          rdata, rresp, rvalid, rready;
  endclocking

  // Master-side reset values (called by the driver while aresetn is low)
  task automatic master_reset();
    awvalid <= 1'b0;
    wvalid  <= 1'b0;
    arvalid <= 1'b0;
    bready  <= 1'b0;
    rready  <= 1'b0;
    awaddr  <= '0;
    awprot  <= '0;
    wdata   <= '0;
    wstrb   <= '0;
    araddr  <= '0;
    arprot  <= '0;
  endtask

endinterface
