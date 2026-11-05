// Interfaces for the cache testbenches.

interface axil_if (input logic clk);
  logic        awvalid, awready;
  logic [31:0] awaddr;
  logic [2:0]  awprot;
  logic        wvalid, wready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        bvalid, bready;
  logic [1:0]  bresp;
  logic        arvalid, arready;
  logic [31:0] araddr;
  logic [2:0]  arprot;
  logic        rvalid, rready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
endinterface

// Core-side request/response port of a cache plus maintenance handshake.
interface cache_if (input logic clk);
  logic        req, gnt, we;
  logic [31:0] addr, wdata, rdata;
  logic [3:0]  be;
  logic        rvalid, err;
  logic        maint_req, maint_inval, maint_done;   // D$: clean/flush, I$: invalidate
  logic        wb_err;
  logic        cache_clean;                         // D$: no dirty line
endinterface
