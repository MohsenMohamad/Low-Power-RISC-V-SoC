// RV32IM 5-stage in-order core, machine mode only.
//
//   IF  : core_fetch (prefetch FIFO, fall-through)
//   ID  : decode, register read, CSR legality, hazard/interrupt checks
//   EX  : ALU, branch resolution (predict not-taken), MUL, iterative DIV
//   MEM : alignment check, data request issue
//   WB  : load data return, CSR access, trap/mret/fence.i/WFI, commit
//
// Precise traps are taken in WB. A data request is issued from MEM only when the
// instruction in WB is certain to commit without a flush, so no younger
// memory side effect can precede an older trap. Interrupts are taken between
// instructions once the pipeline has drained. See doc/CPU.md.
module core_top
  import riscv_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] boot_addr_i,

  // Instruction memory interface
  output logic        imem_req_o,
  input  logic        imem_gnt_i,
  output logic [31:0] imem_addr_o,
  input  logic        imem_rvalid_i,
  input  logic [31:0] imem_rdata_i,
  input  logic        imem_err_i,

  // Data memory interface
  output logic        dmem_req_o,
  input  logic        dmem_gnt_i,
  output logic [31:0] dmem_addr_o,
  output logic        dmem_we_o,
  output logic [3:0]  dmem_be_o,
  output logic [31:0] dmem_wdata_o,
  input  logic        dmem_rvalid_i,
  input  logic [31:0] dmem_rdata_i,
  input  logic        dmem_err_i,

  // Cache maintenance
  output logic        dc_maint_req_o,    // level until done
  output logic        dc_maint_inval_o,  // 1: clean+invalidate, 0: clean only
  input  logic        dc_maint_done_i,   // 1-cycle pulse
  input  logic        dc_wb_err_i,       // sticky write-back error
  output logic        ic_inval_req_o,
  input  logic        ic_inval_done_i,

  // Interrupts / time (synchronous to clk)
  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [63:0] mtime_i,

  // Power management
  input  logic        wfi_hold_i,        // PMU idle handshake active: stay in WFI
  output logic        core_sleep_o,      // in WFI, pipeline and fetch idle, no wake pending
  output logic        wfi_quiet_o,       // in WFI, pipeline and fetch idle (wake may be pending)

  // Commit trace (verification only; unused bits are optimised away)
  output logic        trace_valid_o,
  output logic        trace_irq_o,       // interrupt entry (no instruction)
  output logic        trace_trap_o,      // exception (instruction not retired)
  output logic [31:0] trace_pc_o,
  output logic [31:0] trace_insn_o,
  output logic [31:0] trace_next_pc_o,
  output logic [4:0]  trace_cause_o,
  output logic [31:0] trace_tval_o,
  output logic        trace_rd_we_o,
  output logic [4:0]  trace_rd_o,
  output logic [31:0] trace_rd_wdata_o,
  output logic        trace_mem_we_o,
  output logic        trace_mem_re_o,
  output logic [31:0] trace_mem_addr_o,
  output logic [31:0] trace_mem_wdata_o,
  output logic [3:0]  trace_mem_be_o,
  output logic [2:0]  trace_mip_o
);

  // ===========================================================================
  // Declarations
  // ===========================================================================
  // Fetch
  logic        f_valid, f_err, f_ready, f_idle;
  logic [31:0] f_pc, f_instr;
  logic        redirect;
  logic [31:0] redirect_pc;

  // ID
  ctrl_t       id_ctrl_dec, id_ctrl;
  exc_t        id_exc;
  logic [31:0] id_rs1_val, id_rs2_val;
  logic        id_csr_illegal, id_hazard, id_issue, id_stall;

  // EX
  logic        ex_valid;
  logic [31:0] ex_pc, ex_instr;
  ctrl_t       ex_ctrl;
  exc_t        ex_exc;
  logic [31:0] ex_rs1_q, ex_rs2_q;
  logic [2:0]  ex_mip;
  logic [31:0] ex_rs1, ex_rs2, ex_opa, ex_opb, ex_alu_y, ex_result;
  logic [31:0] ex_target, ex_next_pc;
  logic        ex_taken, ex_cond;
  exc_t        ex_exc_out;
  logic        ex_redirect, ex_stall, ex_div_wait;
  logic [31:0] mul_y, div_y;
  logic        div_busy, div_done, div_start, div_ack;

  // MEM
  logic        mem_valid;
  logic [31:0] mem_pc, mem_instr, mem_result, mem_rs2, mem_next_pc, mem_csr_opnd;
  ctrl_t       mem_ctrl;
  exc_t        mem_exc, mem_exc_out;
  logic [2:0]  mem_mip;
  logic        mem_misaligned, mem_needs_req, mem_issue_ok, mem_stall;
  logic [3:0]  mem_be;
  logic [31:0] mem_wdata;

  // WB
  logic        wb_valid;
  logic [31:0] wb_pc, wb_instr, wb_result, wb_next_pc, wb_csr_opnd, wb_store_data;
/* verilator lint_off UNUSEDSIGNAL */ // WB only needs a subset of the control bits
  ctrl_t       wb_ctrl;
/* verilator lint_on UNUSEDSIGNAL */
  exc_t        wb_exc, wb_exc_final;
  logic [2:0]  wb_mip;
  logic        wb_mem_pending;
  logic [3:0]  wb_be;
  logic        wb_wait_mem, wb_wait_sys, wb_stall, wb_commit, wb_trap, wb_retire, wb_flush;
  logic [31:0] wb_load_data, wb_wdata, wb_flush_pc;
  logic        wb_mem_err;
  logic        wb_is_cachectl, wb_sys_op;

  // CSR
/* verilator lint_off UNUSEDSIGNAL */ // only mcachectl[2:0] of csr_wvalue used here; mtvec[1] is hardwired 0
  logic [31:0] csr_rdata, csr_wvalue, mtvec, mepc;
/* verilator lint_on UNUSEDSIGNAL */
  logic [2:0]  mip;
  logic        irq_wake, irq_take;
  logic [4:0]  irq_cause;
  logic        irq_take_now;
  logic        trap_en, trap_irq;
  logic [4:0]  trap_cause;
  logic [31:0] trap_epc, trap_tval, trap_target;

  // WFI
  logic        wfi_sleep_q;

  // System (fence.i / mcachectl) sequencer
  typedef enum logic [1:0] { SYS_IDLE, SYS_DC, SYS_IC, SYS_DONE } sys_e;
  sys_e        sys_q;
  logic        sys_do_dc, sys_dc_inval, sys_do_ic;
  logic        sys_op_done;

  // ===========================================================================
  // IF
  // ===========================================================================
  core_fetch #(.DEPTH(2)) u_fetch (
    .clk, .rst_n, .boot_addr_i,
    .redirect_i    (redirect),
    .redirect_pc_i (redirect_pc),
    .halt_i        (wfi_sleep_q),
    .imem_req_o, .imem_gnt_i, .imem_addr_o, .imem_rvalid_i, .imem_rdata_i, .imem_err_i,
    .valid_o (f_valid), .pc_o (f_pc), .instr_o (f_instr), .err_o (f_err),
    .ready_i (f_ready),
    .idle_o  (f_idle)
  );

  // ===========================================================================
  // ID
  // ===========================================================================
  core_decoder u_dec (.instr(f_instr), .ctrl(id_ctrl_dec));

  always_comb begin
    id_ctrl = id_ctrl_dec;
    id_exc  = '0;
    if (f_err) begin
      id_exc = '{valid: 1'b1, cause: EXC_INSTR_ACCESS, tval: f_pc};
    end else if (id_ctrl_dec.illegal || (id_ctrl_dec.is_csr && id_csr_illegal)) begin
      // mtval = the faulting instruction bits; a 16-bit encoding (bits[1:0] != 11)
      // only occupies the low parcel, zero-extended.
      id_exc = '{valid: 1'b1, cause: EXC_ILLEGAL,
                 tval: (f_instr[1:0] == 2'b11) ? f_instr : {16'b0, f_instr[15:0]}};
    end else if (id_ctrl_dec.is_ecall) begin
      id_exc = '{valid: 1'b1, cause: EXC_ECALL_M, tval: 32'd0};
    end else if (id_ctrl_dec.is_ebreak) begin
      id_exc = '{valid: 1'b1, cause: EXC_BREAKPOINT, tval: f_pc};
    end
    if (id_exc.valid) begin
      // A trapping instruction has no side effects and no operands.
      id_ctrl.rd_we      = 1'b0;
      id_ctrl.rs1_used   = 1'b0;
      id_ctrl.rs2_used   = 1'b0;
      id_ctrl.is_load    = 1'b0;
      id_ctrl.is_store   = 1'b0;
      id_ctrl.is_branch  = 1'b0;
      id_ctrl.is_jal     = 1'b0;
      id_ctrl.is_jalr    = 1'b0;
      id_ctrl.is_mul     = 1'b0;
      id_ctrl.is_div     = 1'b0;
      id_ctrl.is_csr     = 1'b0;
      id_ctrl.csr_write  = 1'b0;
      id_ctrl.is_mret    = 1'b0;
      id_ctrl.is_wfi     = 1'b0;
      id_ctrl.is_fence_i = 1'b0;
    end
  end

  logic        rf_we;
  logic [31:0] rf_wdata;

  core_regfile u_rf (
    .clk, .rst_n,
    .raddr_a (id_ctrl.rs1), .rdata_a (id_rs1_val),
    .raddr_b (id_ctrl.rs2), .rdata_b (id_rs2_val),
    .we (rf_we), .waddr (wb_ctrl.rd), .wdata (rf_wdata)
  );

  // Load-use / CSR-use hazard: results of loads and CSR reads only exist in WB.
  assign id_hazard = ex_valid && ex_ctrl.rd_we && (ex_ctrl.is_load || ex_ctrl.is_csr) &&
                     ((id_ctrl.rs1_used && id_ctrl.rs1 == ex_ctrl.rd) ||
                      (id_ctrl.rs2_used && id_ctrl.rs2 == ex_ctrl.rd));

  // Interrupts: hold issue, drain, then take between instructions.
  assign irq_take_now = irq_take && f_valid && !ex_valid && !mem_valid && !wb_valid &&
                        !wfi_sleep_q;

  assign id_stall = ex_stall || id_hazard || wfi_sleep_q || irq_take;
  assign id_issue = f_valid && !id_stall && !wb_flush && !ex_redirect;
  assign f_ready  = id_issue;

  // ===========================================================================
  // EX
  // ===========================================================================
  // Forwarding: MEM (non-late results only, guaranteed by id_hazard), then WB.
  always_comb begin
    ex_rs1 = ex_rs1_q;
    ex_rs2 = ex_rs2_q;
    if (wb_valid && wb_ctrl.rd_we && wb_ctrl.rd == ex_ctrl.rs1) ex_rs1 = wb_wdata;
    if (wb_valid && wb_ctrl.rd_we && wb_ctrl.rd == ex_ctrl.rs2) ex_rs2 = wb_wdata;
    if (mem_valid && mem_ctrl.rd_we && mem_ctrl.rd == ex_ctrl.rs1) ex_rs1 = mem_result;
    if (mem_valid && mem_ctrl.rd_we && mem_ctrl.rd == ex_ctrl.rs2) ex_rs2 = mem_result;
  end

  always_comb begin
    unique case (ex_ctrl.opa_sel)
      OPA_PC:   ex_opa = ex_pc;
      OPA_ZERO: ex_opa = 32'd0;
      default:  ex_opa = ex_rs1;
    endcase
    unique case (ex_ctrl.opb_sel)
      OPB_RS2:  ex_opb = ex_rs2;
      OPB_FOUR: ex_opb = 32'd4;
      default:  ex_opb = ex_ctrl.imm;
    endcase
  end

  core_alu u_alu (.op(ex_ctrl.alu_op), .a(ex_opa), .b(ex_opb), .y(ex_alu_y));

  assign div_start = ex_valid && ex_ctrl.is_div && !ex_exc.valid && !div_busy && !div_done &&
                     !mem_stall && !wb_flush;
  assign div_ack   = ex_valid && !ex_stall;

  core_muldiv u_md (
    .clk, .rst_n,
    .mul_op (ex_ctrl.funct3), .mul_a (ex_rs1), .mul_b (ex_rs2), .mul_y (mul_y),
    .div_start (div_start), .div_op (ex_ctrl.funct3), .div_a (ex_rs1), .div_b (ex_rs2),
    .div_ack (div_ack), .div_kill (wb_flush), .div_busy (div_busy), .div_done (div_done), .div_y (div_y)
  );

  assign ex_result = ex_ctrl.is_mul ? mul_y : ex_ctrl.is_div ? div_y : ex_alu_y;

  always_comb begin
    unique case (ex_ctrl.funct3)
      3'b000:  ex_cond = (ex_rs1 == ex_rs2);
      3'b001:  ex_cond = (ex_rs1 != ex_rs2);
      3'b100:  ex_cond = ($signed(ex_rs1) <  $signed(ex_rs2));
      3'b101:  ex_cond = ($signed(ex_rs1) >= $signed(ex_rs2));
      3'b110:  ex_cond = (ex_rs1 <  ex_rs2);
      3'b111:  ex_cond = (ex_rs1 >= ex_rs2);
      default: ex_cond = 1'b0;
    endcase
  end

  assign ex_target  = ex_ctrl.is_jalr ? ((ex_rs1 + ex_ctrl.imm) & ~32'd1) : (ex_pc + ex_ctrl.imm);
  assign ex_taken   = ex_ctrl.is_jal || ex_ctrl.is_jalr || (ex_ctrl.is_branch && ex_cond);
  assign ex_next_pc = ex_taken ? ex_target : ex_pc + 32'd4;

  always_comb begin
    ex_exc_out = ex_exc;
    if (!ex_exc.valid && ex_taken && ex_target[1])
      ex_exc_out = '{valid: 1'b1, cause: EXC_INSTR_MISALIGNED, tval: ex_target};
  end

  assign ex_div_wait = ex_valid && ex_ctrl.is_div && !ex_exc.valid && !div_done;
  assign ex_stall    = mem_stall || ex_div_wait;
  assign ex_redirect = ex_valid && !ex_stall && !wb_flush && ex_taken && !ex_exc_out.valid;

  // ===========================================================================
  // MEM
  // ===========================================================================
  always_comb begin
    unique case (mem_ctrl.funct3[1:0])
      2'b00:   mem_misaligned = 1'b0;
      2'b01:   mem_misaligned = mem_result[0];
      default: mem_misaligned = mem_result[1:0] != 2'b00;
    endcase
    mem_exc_out = mem_exc;
    if (!mem_exc.valid && (mem_ctrl.is_load || mem_ctrl.is_store) && mem_misaligned)
      mem_exc_out = '{valid: 1'b1,
                      cause: mem_ctrl.is_load ? EXC_LOAD_MISALIGNED : EXC_STORE_MISALIGNED,
                      tval: mem_result};
    unique case (mem_ctrl.funct3[1:0])
      2'b00:   begin mem_be = 4'b0001 << mem_result[1:0]; mem_wdata = {4{mem_rs2[7:0]}};  end
      2'b01:   begin mem_be = 4'b0011 << mem_result[1:0]; mem_wdata = {2{mem_rs2[15:0]}}; end
      default: begin mem_be = 4'b1111;                    mem_wdata = mem_rs2;            end
    endcase
  end

  assign mem_needs_req = mem_valid && !mem_exc_out.valid && (mem_ctrl.is_load || mem_ctrl.is_store);
  // WB must be empty or certain to commit this cycle without flushing.
  assign mem_issue_ok  = !wb_valid || (wb_commit && !wb_flush);

  assign dmem_req_o   = mem_needs_req && mem_issue_ok;
  assign dmem_addr_o  = {mem_result[31:2], 2'b00};
  assign dmem_we_o    = mem_ctrl.is_store;
  assign dmem_be_o    = mem_be;
  assign dmem_wdata_o = mem_wdata;

  assign mem_stall = wb_stall || (mem_needs_req && !(dmem_req_o && dmem_gnt_i));

  // ===========================================================================
  // WB
  // ===========================================================================
  assign wb_wait_mem = wb_valid && wb_mem_pending && !dmem_rvalid_i;
  assign wb_mem_err  = wb_valid && wb_mem_pending && dmem_rvalid_i && dmem_err_i;

  assign wb_is_cachectl = wb_ctrl.is_csr && wb_ctrl.csr_write && wb_instr[31:20] == CSR_MCACHECTL;
  assign wb_sys_op   = wb_valid && !wb_exc.valid && (wb_ctrl.is_fence_i || wb_is_cachectl);
  assign wb_wait_sys = wb_sys_op && !sys_op_done;
  assign wb_stall    = wb_wait_mem || wb_wait_sys;
  assign wb_commit   = wb_valid && !wb_stall;

  always_comb begin
    wb_exc_final = wb_exc;
    if (!wb_exc.valid && wb_mem_err)
      wb_exc_final = '{valid: 1'b1,
                       cause: wb_ctrl.is_load ? EXC_LOAD_ACCESS : EXC_STORE_ACCESS,
                       tval: wb_result};
  end

  assign wb_trap   = wb_commit && wb_exc_final.valid;
  assign wb_retire = wb_commit && !wb_exc_final.valid;

  // Load data alignment
  always_comb begin
    logic [31:0] sh;
    sh = dmem_rdata_i >> {wb_result[1:0], 3'b000};
    unique case (wb_ctrl.funct3)
      3'b000:  wb_load_data = {{24{sh[7]}},  sh[7:0]};
      3'b001:  wb_load_data = {{16{sh[15]}}, sh[15:0]};
      3'b100:  wb_load_data = {24'b0, sh[7:0]};
      3'b101:  wb_load_data = {16'b0, sh[15:0]};
      default: wb_load_data = sh;
    endcase
  end

  assign wb_wdata = wb_ctrl.is_load ? wb_load_data : wb_ctrl.is_csr ? csr_rdata : wb_result;
  assign rf_we    = wb_retire && wb_ctrl.rd_we;
  assign rf_wdata = wb_wdata;

  // Flush younger instructions after: traps, mret, CSR writes, fence.i, wfi.
  assign wb_flush = wb_trap ||
                    (wb_retire && (wb_ctrl.is_mret || wb_ctrl.csr_write ||
                                   wb_ctrl.is_fence_i || wb_ctrl.is_wfi));

  // ===========================================================================
  // Traps and redirects
  // ===========================================================================
  assign trap_en    = wb_trap || irq_take_now;
  assign trap_irq   = irq_take_now;
  assign trap_cause = irq_take_now ? irq_cause : wb_exc_final.cause;
  assign trap_epc   = irq_take_now ? f_pc : wb_pc;
  assign trap_tval  = irq_take_now ? 32'd0 : wb_exc_final.tval;
  assign trap_target = {mtvec[31:2], 2'b00} +
                       ((mtvec[0] && trap_irq) ? {25'b0, trap_cause, 2'b00} : 32'd0);

  always_comb begin
    if (trap_en)                          wb_flush_pc = trap_target;
    else if (wb_ctrl.is_mret)             wb_flush_pc = mepc;
    else                                  wb_flush_pc = wb_pc + 32'd4;
  end

  assign redirect    = wb_flush || irq_take_now || ex_redirect;
  assign redirect_pc = (wb_flush || irq_take_now) ? wb_flush_pc : ex_target;

  // ===========================================================================
  // CSR file
  // ===========================================================================
  core_csr u_csr (
    .clk, .rst_n,
    .chk_addr     (f_instr[31:20]),
    .chk_write    (id_ctrl_dec.csr_write),
    .chk_illegal  (id_csr_illegal),
    .csr_access   (wb_retire && wb_ctrl.is_csr),
    .csr_addr     (wb_instr[31:20]),
    .csr_op       (wb_ctrl.funct3[1:0]),
    .csr_write    (wb_ctrl.csr_write),
    .csr_operand  (wb_csr_opnd),
    .csr_mip_view (wb_mip),
    .csr_rdata    (csr_rdata),
    .csr_wvalue   (csr_wvalue),
    .trap_en, .trap_irq, .trap_cause, .trap_epc, .trap_tval,
    .mret_en      (wb_retire && wb_ctrl.is_mret),
    .instret_inc  (wb_retire),
    .irq_i        ({irq_external_i, irq_timer_i, irq_software_i}),
    .mtime_i,
    .dcache_err_i (dc_wb_err_i),
    .mip_o        (mip),
    .irq_wake_o   (irq_wake),
    .irq_take_o   (irq_take),
    .irq_cause_o  (irq_cause),
    .mtvec_o      (mtvec),
    .mepc_o       (mepc)
  );

  // ===========================================================================
  // fence.i / mcachectl sequencer
  //   fence.i      : D-cache clean, then I-cache invalidate
  //   mcachectl[0] : D-cache clean + invalidate
  //   mcachectl[1] : I-cache invalidate
  //   mcachectl[2] : D-cache clean
  // ===========================================================================
  assign sys_do_dc    = wb_ctrl.is_fence_i || csr_wvalue[0] || csr_wvalue[2];
  assign sys_dc_inval = !wb_ctrl.is_fence_i && csr_wvalue[0];
  assign sys_do_ic    = wb_ctrl.is_fence_i || csr_wvalue[1];
  assign sys_op_done  = (sys_q == SYS_DONE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sys_q <= SYS_IDLE;
    end else begin
      unique case (sys_q)
        SYS_IDLE: if (wb_sys_op) sys_q <= sys_do_dc ? SYS_DC : sys_do_ic ? SYS_IC : SYS_DONE;
        SYS_DC:   if (dc_maint_done_i) sys_q <= sys_do_ic ? SYS_IC : SYS_DONE;
        SYS_IC:   if (ic_inval_done_i) sys_q <= SYS_DONE;
        SYS_DONE: sys_q <= SYS_IDLE;
        default:  sys_q <= SYS_IDLE;
      endcase
    end
  end

  assign dc_maint_req_o   = (sys_q == SYS_DC);
  assign dc_maint_inval_o = sys_dc_inval;
  assign ic_inval_req_o   = (sys_q == SYS_IC);

  // ===========================================================================
  // WFI
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                              wfi_sleep_q <= 1'b0;
    else if (wb_retire && wb_ctrl.is_wfi)    wfi_sleep_q <= 1'b1;
    // While the PMU idle handshake is active (idle_req high or idle_ack still
    // asserted) the core must not leave WFI: the PMU may be gating the clock
    // or removing power (doc/CPU_SOC_INTERFACE.md, idle handshake).
    else if (irq_wake && !wfi_hold_i)        wfi_sleep_q <= 1'b0;
  end

  assign wfi_quiet_o  = wfi_sleep_q && f_idle && !ex_valid && !mem_valid && !wb_valid;

  assign core_sleep_o = wfi_sleep_q && !irq_wake && f_idle &&
                        !ex_valid && !mem_valid && !wb_valid;

  // ===========================================================================
  // Pipeline registers
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_valid  <= 1'b0;
      mem_valid <= 1'b0;
      wb_valid  <= 1'b0;
      wb_mem_pending <= 1'b0;
    end else begin
      // WB
      if (!wb_stall) begin
        wb_valid       <= mem_valid && !mem_stall && !wb_flush;
        wb_mem_pending <= dmem_req_o && dmem_gnt_i;
      end
      // MEM
      if (wb_flush)        mem_valid <= 1'b0;
      else if (!mem_stall) mem_valid <= ex_valid && !ex_stall;
      // EX
      if (wb_flush)        ex_valid <= 1'b0;
      else if (!ex_stall)  ex_valid <= id_issue;
    end
  end

  always_ff @(posedge clk) begin
    // EX
    if (!ex_stall) begin
      ex_pc    <= f_pc;
      ex_instr <= f_instr;
      ex_ctrl  <= id_ctrl;
      ex_exc   <= id_exc;
      ex_rs1_q <= id_rs1_val;
      ex_rs2_q <= id_rs2_val;
      ex_mip   <= mip;
    end else begin
      // Hold: keep forwarded operands, since the producer may leave WB.
      ex_rs1_q <= ex_rs1;
      ex_rs2_q <= ex_rs2;
    end
    // MEM
    if (!mem_stall) begin
      mem_pc       <= ex_pc;
      mem_instr    <= ex_instr;
      mem_ctrl     <= ex_ctrl;
      mem_exc      <= ex_exc_out;
      mem_result   <= ex_result;
      mem_rs2      <= ex_rs2;
      mem_next_pc  <= ex_next_pc;
      mem_csr_opnd <= ex_ctrl.funct3[2] ? ex_ctrl.imm : ex_rs1;
      mem_mip      <= ex_mip;
    end
    // WB
    if (!wb_stall) begin
      wb_pc         <= mem_pc;
      wb_instr      <= mem_instr;
      wb_ctrl       <= mem_ctrl;
      wb_exc        <= mem_exc_out;
      wb_result     <= mem_result;
      wb_next_pc    <= mem_next_pc;
      wb_csr_opnd   <= mem_csr_opnd;
      wb_mip        <= mem_mip;
      wb_store_data <= mem_wdata;
      wb_be         <= mem_be;
    end
  end

  // ===========================================================================
  // Trace
  // ===========================================================================
  assign trace_valid_o     = wb_commit || irq_take_now;
  assign trace_irq_o       = irq_take_now;
  assign trace_trap_o      = wb_trap;
  assign trace_pc_o        = irq_take_now ? f_pc : wb_pc;
  assign trace_insn_o      = wb_instr;
  assign trace_next_pc_o   = (wb_flush || irq_take_now) ? wb_flush_pc : wb_next_pc;
  assign trace_cause_o     = trap_cause;
  assign trace_tval_o      = trap_tval;
  assign trace_rd_we_o     = rf_we;
  assign trace_rd_o        = wb_ctrl.rd;
  assign trace_rd_wdata_o  = rf_wdata;
  assign trace_mem_we_o    = wb_retire && wb_ctrl.is_store;
  assign trace_mem_re_o    = wb_retire && wb_ctrl.is_load;
  assign trace_mem_addr_o  = wb_result;
  assign trace_mem_wdata_o = wb_store_data;
  assign trace_mem_be_o    = wb_be;
  assign trace_mip_o       = irq_take_now ? mip : wb_mip;

endmodule
