// AXI4-Lite interface used by the debug testbenches (14-bit address covers
// one block (4 KB) or the dbg_subsys wrapper (16 KB)).
interface dbg_axil_if (input logic clk, input logic rst_n);
  logic [13:0] awaddr;  logic [2:0] awprot;  logic awvalid, awready;
  logic [31:0] wdata;   logic [3:0] wstrb;   logic wvalid,  wready;
  logic [1:0]  bresp;   logic bvalid, bready;
  logic [13:0] araddr;  logic [2:0] arprot;  logic arvalid, arready;
  logic [31:0] rdata;   logic [1:0] rresp;   logic rvalid,  rready;
endinterface
