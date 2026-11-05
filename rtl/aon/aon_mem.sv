// -----------------------------------------------------------------------------
// aon_mem - register-request front end for the boot ROM / main RAM macros
//
// IS_ROM=1 : tech_rom, writes are answered with an error.
// IS_ROM=0 : tech_ram_sp with retention input. While ret_i is high the
//            macro must not be accessed; any request is answered with an error
//            without touching the macro.
// -----------------------------------------------------------------------------
module aon_mem #(
  parameter bit    IS_ROM    = 1'b0,
  parameter int    BYTES     = 16384,
  parameter string INIT_FILE = ""
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       ret_i,
  input  logic                       req_i,
  input  logic                       we_i,
  input  logic [$clog2(BYTES)-1:0]   addr_i,
  input  logic [31:0]                wdata_i,
  input  logic [3:0]                 wstrb_i,
  output logic                       ack_o,
  output logic [31:0]                rdata_o,
  output logic                       err_o
);
  localparam int WORDS = BYTES / 4;
  localparam int WAW   = $clog2(WORDS);

  logic        pend_q;
  logic        cs;
  logic        bad;
  logic [31:0] mem_rdata;

  assign bad = (IS_ROM && we_i) || (!IS_ROM && ret_i);
  assign cs  = req_i && !pend_q && !bad;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pend_q <= 1'b0;
    else         pend_q <= req_i && !pend_q;
  end

  // Bad requests are answered in the issue cycle, good ones one cycle later.
  assign ack_o   = req_i && (bad ? !pend_q : pend_q);
  assign err_o   = bad;
  assign rdata_o = bad ? 32'h0 : mem_rdata;

  if (IS_ROM) begin : g_rom
    tech_rom #(.WORDS(WORDS), .INIT_FILE(INIT_FILE)) u_rom (
      .clk_i (clk_i), .cs_i (cs), .addr_i (addr_i[WAW+1:2]), .rdata_o (mem_rdata)
    );
    logic unused;
    assign unused = ^{ret_i, wdata_i, wstrb_i, addr_i[1:0]};
  end else begin : g_ram
    tech_ram_sp #(.WORDS(WORDS), .INIT_FILE(INIT_FILE)) u_ram (
      .clk_i (clk_i), .rst_ni (rst_ni), .ret_i (ret_i), .cs_i (cs), .we_i (we_i),
      .be_i (wstrb_i), .addr_i (addr_i[WAW+1:2]), .wdata_i (wdata_i), .rdata_o (mem_rdata)
    );
    logic unused;
    assign unused = ^{addr_i[1:0]};
  end
endmodule
