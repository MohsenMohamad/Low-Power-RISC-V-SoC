// Instruction fetch unit (IF stage).
//
// Issues sequential fetches on the instruction memory interface and buffers
// responses in a small FIFO with fall-through, so a 1-cycle-latency I-cache
// hit delivers one instruction per cycle. On a redirect the FIFO is cleared and
// responses to requests already in flight are discarded.
//
// Memory interface (shared with the caches):
//   request : req/addr held by the requester; accepted when req && gnt.
//             A requester may change or drop an un-granted request.
//   response: exactly one rvalid (with rdata/err) per accepted request, in
//             order, at the earliest one cycle after acceptance.
module core_fetch #(
  parameter int DEPTH = 2
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] boot_addr_i,

  input  logic        redirect_i,
  input  logic [31:0] redirect_pc_i,
  input  logic        halt_i,        // do not start new fetches (WFI sleep)

  output logic        imem_req_o,
  input  logic        imem_gnt_i,
  output logic [31:0] imem_addr_o,
  input  logic        imem_rvalid_i,
  input  logic [31:0] imem_rdata_i,
  input  logic        imem_err_i,

  output logic        valid_o,
  output logic [31:0] pc_o,
  output logic [31:0] instr_o,
  output logic        err_o,
  input  logic        ready_i,       // ID consumes the head entry

  output logic        idle_o         // no fetch in flight
);

  localparam int CW = $clog2(DEPTH + 1);

  logic [31:0] pc_q;         // address of the next request
  logic [31:0] resp_pc_q;    // pc of the next useful response
  logic [CW-1:0] outst_q;    // requests in flight (incl. ones to discard)
  logic [CW-1:0] discard_q;  // in-flight responses to drop

  logic [31:0] fifo_instr [DEPTH];
  logic [31:0] fifo_pc    [DEPTH];
  logic        fifo_err   [DEPTH];
  logic [CW-1:0] cnt_q;
  logic [$clog2(DEPTH)-1:0] rd_q, wr_q;

  logic rsp_ok, push, pop, bypass, issue;
  logic [CW-1:0] cnt_eff;

  assign rsp_ok  = imem_rvalid_i && (discard_q == '0);
  assign cnt_eff = redirect_i ? '0 : cnt_q;

  // Request
  assign imem_req_o  = !halt_i && ((32'(cnt_eff) + 32'(outst_q)) < DEPTH);
  assign imem_addr_o = redirect_i ? redirect_pc_i : pc_q;
  assign issue       = imem_req_o && imem_gnt_i;

  // Output (fall-through when FIFO empty)
  assign valid_o = (cnt_q != '0) || rsp_ok;
  assign pc_o    = (cnt_q != '0) ? fifo_pc[rd_q]    : resp_pc_q;
  assign instr_o = (cnt_q != '0) ? fifo_instr[rd_q] : imem_rdata_i;
  assign err_o   = (cnt_q != '0) ? fifo_err[rd_q]   : imem_err_i;

  assign bypass = rsp_ok && (cnt_q == '0) && ready_i;
  assign pop    = !redirect_i && ready_i && (cnt_q != '0);
  assign push   = !redirect_i && rsp_ok && !bypass;

  assign idle_o = (outst_q == '0);

  function automatic logic [$clog2(DEPTH)-1:0] inc_ptr(input logic [$clog2(DEPTH)-1:0] p);
    return (32'(p) == DEPTH - 1) ? '0 : p + 1'b1;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q      <= boot_addr_i;
      resp_pc_q <= boot_addr_i;
      outst_q   <= '0;
      discard_q <= '0;
      cnt_q     <= '0;
      rd_q      <= '0;
      wr_q      <= '0;
    end else begin
      // In-flight tracking
      outst_q <= outst_q + CW'(issue) - CW'(imem_rvalid_i);

      if (redirect_i) begin
        discard_q <= outst_q - CW'(imem_rvalid_i);
        resp_pc_q <= redirect_pc_i;
        pc_q      <= issue ? redirect_pc_i + 32'd4 : redirect_pc_i;
        cnt_q     <= '0;
        rd_q      <= '0;
        wr_q      <= '0;
      end else begin
        if (imem_rvalid_i && discard_q != '0) discard_q <= discard_q - 1'b1;
        if (rsp_ok) resp_pc_q <= resp_pc_q + 32'd4;
        if (issue)  pc_q      <= pc_q + 32'd4;
        if (push) begin
          fifo_instr[wr_q] <= imem_rdata_i;
          fifo_pc[wr_q]    <= resp_pc_q;
          fifo_err[wr_q]   <= imem_err_i;
          wr_q             <= inc_ptr(wr_q);
        end
        if (pop) rd_q <= inc_ptr(rd_q);
        cnt_q <= cnt_q + CW'(push) - CW'(pop);
      end
    end
  end

endmodule
