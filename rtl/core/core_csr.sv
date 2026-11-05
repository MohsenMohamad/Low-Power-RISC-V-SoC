// Machine-mode CSR file (M-mode only hart, RV32).
//
// All architectural updates happen at commit (WB) or at interrupt entry.
// Implemented: mstatus/mstatush, misa (read-only), mie, mip (read-only),
// mtvec (direct/vectored), mscratch, mepc, mcause, mtval, mcountinhibit,
// mcycle/minstret(+h), cycle/instret/time(+h) shadows, mhpmcounter3-31(+h)
// and mhpmevent3-31 (read zero), pmpcfg0-15/pmpaddr0-63 (no PMP: read zero),
// mvendorid/marchid/mimpid/mhartid/mconfigptr, and the custom mcachectl.
module core_csr
  import riscv_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Legality check for the instruction in ID
  input  logic [11:0] chk_addr,
  input  logic        chk_write,
  output logic        chk_illegal,

  // CSR access at commit
  input  logic        csr_access,     // retiring CSR instruction
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,         // funct3[1:0]: 01 RW, 10 RS, 11 RC
  input  logic        csr_write,      // instruction performs a write
  input  logic [31:0] csr_operand,    // rs1 value or zimm
  input  logic [2:0]  csr_mip_view,   // {MEIP,MTIP,MSIP} sampled at issue
  output logic [31:0] csr_rdata,      // old value (combinational)
  output logic [31:0] csr_wvalue,     // value being written (for side effects)

  // Trap entry / return
  input  logic        trap_en,
  input  logic        trap_irq,
  input  logic [4:0]  trap_cause,
/* verilator lint_off UNUSEDSIGNAL */ // epc is word aligned
  input  logic [31:0] trap_epc,
/* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] trap_tval,
  input  logic        mret_en,
  input  logic        instret_inc,

  // Interrupt inputs (already synchronous to clk)
  input  logic [2:0]  irq_i,          // {MEIP,MTIP,MSIP}
  input  logic [63:0] mtime_i,
  input  logic        dcache_err_i,   // sticky write-back error indication

  output logic [2:0]  mip_o,          // registered {MEIP,MTIP,MSIP}
  output logic        irq_wake_o,     // (mip & mie) != 0  (WFI wake-up)
  output logic        irq_take_o,     // wake & mstatus.MIE
  output logic [4:0]  irq_cause_o,    // highest-priority pending+enabled
  output logic [31:0] mtvec_o,
  output logic [31:0] mepc_o
);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mstatus_mie_q, mstatus_mpie_q;
  logic [2:0]  mie_q;                 // {MEIE,MTIE,MSIE}
  logic [2:0]  mip_q;
  logic [31:0] mtvec_q;               // bit 1 always 0
  logic [31:0] mscratch_q;
  logic [31:2] mepc_q;
  logic [31:0] mcause_q;
  logic [31:0] mtval_q;
  logic        inh_cy_q, inh_ir_q;
  logic [63:0] mcycle_q, minstret_q;

  // ---------------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------------
  function automatic logic csr_exists(input logic [11:0] a);
    logic e;
    e = 1'b0;
    unique case (a)
      CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC, CSR_MSTATUSH, CSR_MCOUNTINH,
      CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
      CSR_CYCLE, CSR_INSTRET, CSR_CYCLEH, CSR_INSTRETH, 12'hC01, 12'hC81,
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID, CSR_MCONFIGPTR,
      CSR_MCACHECTL: e = 1'b1;
      default: ;
    endcase
    // mhpmcounter3..31 (B03-B1F), mhpmcounter3h..31h (B83-B9F)
    if ((a[11:5] == 7'b1011_000 || a[11:5] == 7'b1011_100) && a[4:0] >= 5'd3) e = 1'b1;
    // mhpmevent3..31 (323-33F)
    if (a[11:5] == 7'b0011_001 && a[4:0] >= 5'd3) e = 1'b1;
    // pmpcfg0..15 (3A0-3AF), pmpaddr0..63 (3B0-3EF)
    if (a[11:4] == 8'h3A || (a >= 12'h3B0 && a <= 12'h3EF)) e = 1'b1;
    return e;
  endfunction

  assign chk_illegal = !csr_exists(chk_addr) || (chk_write && chk_addr[11:10] == 2'b11);

  // ---------------------------------------------------------------------------
  // Read mux
  // ---------------------------------------------------------------------------
  logic [31:0] mstatus_val, mie_val, mip_view_val;

  assign mstatus_val  = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};
  assign mie_val      = {20'b0, mie_q[2], 3'b0, mie_q[1], 3'b0, mie_q[0], 3'b0};
  assign mip_view_val = {20'b0, csr_mip_view[2], 3'b0, csr_mip_view[1], 3'b0, csr_mip_view[0], 3'b0};

  always_comb begin
    csr_rdata = '0;
    unique case (csr_addr)
      CSR_MSTATUS:    csr_rdata = mstatus_val;
      CSR_MISA:       csr_rdata = MISA_VALUE;
      CSR_MIE:        csr_rdata = mie_val;
      CSR_MTVEC:      csr_rdata = mtvec_q;
      CSR_MCOUNTINH:  csr_rdata = {29'b0, inh_ir_q, 1'b0, inh_cy_q};
      CSR_MSCRATCH:   csr_rdata = mscratch_q;
      CSR_MEPC:       csr_rdata = {mepc_q, 2'b00};
      CSR_MCAUSE:     csr_rdata = mcause_q;
      CSR_MTVAL:      csr_rdata = mtval_q;
      CSR_MIP:        csr_rdata = mip_view_val;
      CSR_MCYCLE,   CSR_CYCLE:    csr_rdata = mcycle_q[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:   csr_rdata = mcycle_q[63:32];
      CSR_MINSTRET, CSR_INSTRET:  csr_rdata = minstret_q[31:0];
      CSR_MINSTRETH,CSR_INSTRETH: csr_rdata = minstret_q[63:32];
      12'hC01:        csr_rdata = mtime_i[31:0];
      12'hC81:        csr_rdata = mtime_i[63:32];
      CSR_MCACHECTL:  csr_rdata = {dcache_err_i, 31'b0};
      default:        csr_rdata = '0;   // all other existing CSRs read zero
    endcase
  end

  always_comb begin
    unique case (csr_op)
      2'b01:   csr_wvalue = csr_operand;
      2'b10:   csr_wvalue = csr_rdata | csr_operand;
      2'b11:   csr_wvalue = csr_rdata & ~csr_operand;
      default: csr_wvalue = csr_operand;
    endcase
  end

  logic do_write;
  assign do_write = csr_access && csr_write;

  // ---------------------------------------------------------------------------
  // Interrupts
  // ---------------------------------------------------------------------------
  logic [2:0] pend;
  assign pend        = mip_q & mie_q;
  assign mip_o       = mip_q;
  assign irq_wake_o  = |pend;
  assign irq_take_o  = (|pend) && mstatus_mie_q;
  // Priority: MEI > MSI > MTI
  assign irq_cause_o = pend[2] ? 5'd11 : pend[0] ? 5'd3 : 5'd7;

  assign mtvec_o = mtvec_q;
  assign mepc_o  = {mepc_q, 2'b00};

  // ---------------------------------------------------------------------------
  // Sequential
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_q          <= '0;
      mip_q          <= '0;
      mtvec_q        <= '0;
      mscratch_q     <= '0;
      mepc_q         <= '0;
      mcause_q       <= '0;
      mtval_q        <= '0;
      inh_cy_q       <= 1'b0;
      inh_ir_q       <= 1'b0;
      mcycle_q       <= '0;
      minstret_q     <= '0;
    end else begin
      mip_q <= irq_i;

      // Counters: an explicit write to either half suppresses the increment of
      // the whole 64-bit counter for that cycle (write takes precedence).
      if (!inh_cy_q && !(do_write && (csr_addr == CSR_MCYCLE || csr_addr == CSR_MCYCLEH)))
        mcycle_q <= mcycle_q + 64'd1;
      if (instret_inc && !inh_ir_q &&
          !(do_write && (csr_addr == CSR_MINSTRET || csr_addr == CSR_MINSTRETH)))
        minstret_q <= minstret_q + 64'd1;

      if (trap_en) begin
        mepc_q         <= trap_epc[31:2];
        mcause_q       <= {trap_irq, 26'b0, trap_cause};
        mtval_q        <= trap_tval;
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
      end else if (mret_en) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end else if (do_write) begin
        unique case (csr_addr)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= csr_wvalue[MSTATUS_MIE];
            mstatus_mpie_q <= csr_wvalue[MSTATUS_MPIE];
          end
          CSR_MIE:       mie_q      <= {csr_wvalue[IRQ_MEI], csr_wvalue[IRQ_MTI], csr_wvalue[IRQ_MSI]};
          CSR_MTVEC:     mtvec_q    <= {csr_wvalue[31:2], 1'b0, csr_wvalue[0]};
          CSR_MSCRATCH:  mscratch_q <= csr_wvalue;
          CSR_MEPC:      mepc_q     <= csr_wvalue[31:2];
          CSR_MCAUSE:    mcause_q   <= csr_wvalue;
          CSR_MTVAL:     mtval_q    <= csr_wvalue;
          CSR_MCOUNTINH: begin
            inh_cy_q <= csr_wvalue[0];
            inh_ir_q <= csr_wvalue[2];
          end
          CSR_MCYCLE:    mcycle_q[31:0]    <= csr_wvalue;
          CSR_MCYCLEH:   mcycle_q[63:32]   <= csr_wvalue;
          CSR_MINSTRET:  minstret_q[31:0]  <= csr_wvalue;
          CSR_MINSTRETH: minstret_q[63:32] <= csr_wvalue;
          default: ;
        endcase
      end
    end
  end

endmodule
