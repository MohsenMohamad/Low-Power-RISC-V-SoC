// -----------------------------------------------------------------------------
// cpu_core_picorv32 - TEMPORARY stand-in for the in-house RV32IM core
//
// Presents the core interface the SoC expects from the in-house CPU:
//   * AXI4-Lite master (single port, one transaction in flight)
//   * machine interrupt lines meip/mtip/msip (asynchronous, PD_AON)
//   * WFI status (core_sleep_o) and the idle_req/idle_ack PMU handshake
//   * cache_clean_o (no dirty D-cache lines; PicoRV32 has no cache -> 1)
//
// PicoRV32 has no WFI instruction. The wrapper emulates it on the native
// memory interface: when an instruction fetch returns the WFI encoding
// (0x10500073) the core is handed a NOP instead. PicoRV32 may prefetch that
// word before older instructions (e.g. a store) have executed, so the wait
// state is only entered at the next sequential instruction fetch (address of
// the WFI + 4): at that point every older instruction has retired. That fetch
// is held back until an interrupt line is pending. While held there are no
// outstanding bus transactions, so core_sleep_o is a clean "WFI and
// quiescent" indication. A non-sequential fetch (the prefetched WFI was
// discarded by a taken branch) cancels the pending WFI.
//
// PMU handshake (4-phase): idle_req (from PD_AON, synchronized here) is
// acknowledged only while in WFI; while idle_req is high the core does not
// leave WFI, so the PMU can safely gate the clock / remove power. The wrapper
// leaves WFI only after idle_req has been withdrawn.
//
// PicoRV32 uses a synchronous reset; the PMU provides a reset-clocking window
// (RST_CLK_CYCLES) after power-up so the reset is sampled.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"
module cpu_core_picorv32 #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // interrupts (asynchronous)
  input  logic        meip_i,
  input  logic        mtip_i,
  input  logic        msip_i,
  // PMU handshake
  input  logic        idle_req_i,     // asynchronous
  output logic        idle_ack_o,
  output logic        core_sleep_o,
  output logic        cache_clean_o,
  // AXI4-Lite master
  output logic        m_awvalid_o,
  input  logic        m_awready_i,
  output logic [31:0] m_awaddr_o,
  output logic [2:0]  m_awprot_o,
  output logic        m_wvalid_o,
  input  logic        m_wready_i,
  output logic [31:0] m_wdata_o,
  output logic [3:0]  m_wstrb_o,
  input  logic        m_bvalid_i,
  output logic        m_bready_o,
  input  logic [1:0]  m_bresp_i,
  output logic        m_arvalid_o,
  input  logic        m_arready_i,
  output logic [31:0] m_araddr_o,
  output logic [2:0]  m_arprot_o,
  input  logic        m_rvalid_i,
  output logic        m_rready_o,
  input  logic [31:0] m_rdata_i,
  input  logic [1:0]  m_rresp_i,
  output logic        trap_o
);
  localparam logic [31:0] INSN_WFI = 32'h1050_0073;
  localparam logic [31:0] INSN_NOP = 32'h0000_0013;

  // ---------------- synchronizers (PD_CPU) ----------------
  logic [3:0] async_in, sync_in;
  logic       meip_s, mtip_s, msip_s, idle_req_s;
  assign async_in = {idle_req_i, msip_i, mtip_i, meip_i};
  tech_sync #(.WIDTH(4), .STAGES(2)) u_sync (
    .clk_i (clk_i), .rst_ni (rst_ni), .d_i (async_in), .q_o (sync_in)
  );
  assign {idle_req_s, msip_s, mtip_s, meip_s} = sync_in;

  // ---------------- PicoRV32 ----------------
  logic        mem_valid, mem_instr, mem_ready;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0]  mem_wstrb;
  logic        trap;
  // PCPI co-processor port (MUL/DIV instantiated here with named instances
  // so every PD_CPU state element has a tool-independent hierarchical path).
  logic        pcpi_valid;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
  logic        mul_wr, mul_wait, mul_ready, div_wr, div_wait, div_ready;
  logic [31:0] mul_rd, div_rd;

  /* verilator lint_off PINCONNECTEMPTY */
  picorv32 #(
    .ENABLE_COUNTERS   (1),
    .ENABLE_COUNTERS64 (1),
    .ENABLE_REGS_16_31 (1),
    .ENABLE_REGS_DUALPORT (1),
    .LATCHED_MEM_RDATA (0),
    .TWO_STAGE_SHIFT   (1),
    .BARREL_SHIFTER    (1),
    .COMPRESSED_ISA    (0),
    .CATCH_MISALIGN    (1),
    .CATCH_ILLINSN     (1),
    .ENABLE_PCPI       (1),
    .ENABLE_MUL        (0),
    .ENABLE_FAST_MUL   (0),
    .ENABLE_DIV        (0),
    .ENABLE_IRQ        (0),
    .ENABLE_TRACE      (0),
    .REGS_INIT_ZERO    (0),
    .PROGADDR_RESET    (RESET_ADDR)
  ) u_core (
    .clk          (clk_i),
    .resetn       (rst_ni),
    .trap         (trap),
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),
    .mem_la_read  (),
    .mem_la_write (),
    .mem_la_addr  (),
    .mem_la_wdata (),
    .mem_la_wstrb (),
    .pcpi_valid   (pcpi_valid),
    .pcpi_insn    (pcpi_insn),
    .pcpi_rs1     (pcpi_rs1),
    .pcpi_rs2     (pcpi_rs2),
    .pcpi_wr      (mul_wr | div_wr),
    .pcpi_rd      (mul_wr ? mul_rd : div_rd),
    .pcpi_wait    (mul_wait | div_wait),
    .pcpi_ready   (mul_ready | div_ready),
    .irq          (32'b0),
    .eoi          (),
    .trace_valid  (),
    .trace_data   ()
  );
  /* verilator lint_on PINCONNECTEMPTY */
  assign trap_o = trap;

  picorv32_pcpi_mul u_mul (
    .clk (clk_i), .resetn (rst_ni), .pcpi_valid (pcpi_valid), .pcpi_insn (pcpi_insn),
    .pcpi_rs1 (pcpi_rs1), .pcpi_rs2 (pcpi_rs2), .pcpi_wr (mul_wr), .pcpi_rd (mul_rd),
    .pcpi_wait (mul_wait), .pcpi_ready (mul_ready)
  );

  picorv32_pcpi_div u_div (
    .clk (clk_i), .resetn (rst_ni), .pcpi_valid (pcpi_valid), .pcpi_insn (pcpi_insn),
    .pcpi_rs1 (pcpi_rs1), .pcpi_rs2 (pcpi_rs2), .pcpi_wr (div_wr), .pcpi_rd (div_rd),
    .pcpi_wait (div_wait), .pcpi_ready (div_ready)
  );

  // ---------------- WFI emulation ----------------
  logic        wfi_q;        // waiting for an interrupt
  logic        wfi_seen_q;   // WFI fetched, not yet retired
  logic [31:0] wfi_next_q;   // address of the instruction after the WFI
  logic        irq_pending;
  logic        wfi_hit;
  logic        wfi_enter;

  assign irq_pending = meip_s | mtip_s | msip_s;

  // ---------------- native -> AXI4-Lite master ----------------
  // Plain vector (not an enum) so the OFF-state corruption model can write
  // arbitrary values into it.
  localparam logic [1:0] A_IDLE = 2'd0, A_WRITE = 2'd1, A_READ = 2'd2, A_DONE = 2'd3;
  logic [1:0]  astate_q;
  logic        aw_done_q, w_done_q;
  logic [31:0] rdata_q;
  logic        req_ok;

  // The sequential fetch after a WFI enters the wait state instead of starting.
  assign wfi_enter = wfi_seen_q && mem_valid && mem_instr && (mem_addr == wfi_next_q);
  // A new request may start only outside WFI.
  assign req_ok = mem_valid && !wfi_q && !wfi_enter;

  assign m_awaddr_o  = {mem_addr[31:2], 2'b00};
  assign m_awprot_o  = 3'b000;
  assign m_wdata_o   = mem_wdata;
  assign m_wstrb_o   = mem_wstrb;
  assign m_araddr_o  = {mem_addr[31:2], 2'b00};
  assign m_arprot_o  = mem_instr ? 3'b100 : 3'b000;
  assign m_awvalid_o = (astate_q == A_WRITE) && !aw_done_q;
  assign m_wvalid_o  = (astate_q == A_WRITE) && !w_done_q;
  assign m_bready_o  = (astate_q == A_WRITE);
  assign m_arvalid_o = (astate_q == A_READ) && !aw_done_q;
  assign m_rready_o  = (astate_q == A_READ);

  assign mem_ready = (astate_q == A_DONE);
  assign wfi_hit   = mem_instr && (rdata_q == INSN_WFI);
  assign mem_rdata = wfi_hit ? INSN_NOP : rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      astate_q  <= A_IDLE;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      rdata_q   <= '0;
      wfi_q      <= 1'b0;
      wfi_seen_q <= 1'b0;
      wfi_next_q <= '0;
    end else begin
      case (astate_q)
        A_IDLE: begin
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          if (wfi_enter) begin
            wfi_q      <= 1'b1;
            wfi_seen_q <= 1'b0;
          end else if (req_ok) begin
            astate_q <= (|mem_wstrb) ? A_WRITE : A_READ;
            if (mem_instr) wfi_seen_q <= 1'b0;   // non-sequential: cancelled
          end
        end
        A_WRITE: begin
          if (m_awvalid_o && m_awready_i) aw_done_q <= 1'b1;
          if (m_wvalid_o  && m_wready_i)  w_done_q  <= 1'b1;
          if (m_bvalid_i) begin
            rdata_q  <= '0;
            astate_q <= A_DONE;
          end
        end
        A_READ: begin
          if (m_arvalid_o && m_arready_i) aw_done_q <= 1'b1;
          if (m_rvalid_i) begin
            rdata_q  <= m_rdata_i;
            astate_q <= A_DONE;
          end
        end
        A_DONE: begin
          // mem_ready is high this cycle; PicoRV32 consumes the data.
          if (wfi_hit) begin
            wfi_seen_q <= 1'b1;
            wfi_next_q <= {mem_addr[31:2], 2'b00} + 32'd4;
          end
          astate_q <= A_IDLE;
        end
        default: astate_q <= A_IDLE;
      endcase

      // Leave WFI on a pending interrupt once the PMU withdrew idle_req.
      if (wfi_q && irq_pending && !idle_req_s) wfi_q <= 1'b0;
    end
  end

  // ---------------- PMU handshake ----------------
  // Both status outputs are flop outputs (glitch-free for the synchronizers).
  logic idle_ack_q, core_sleep_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      idle_ack_q   <= 1'b0;
      core_sleep_q <= 1'b0;
    end else begin
      idle_ack_q   <= idle_req_s && (wfi_q || idle_ack_q);
      core_sleep_q <= wfi_q && (astate_q == A_IDLE) && !(irq_pending && !idle_req_s);
    end
  end

  assign idle_ack_o    = idle_ack_q;
  assign core_sleep_o  = core_sleep_q;
  assign cache_clean_o = 1'b1;

  logic unused;
  assign unused = ^{m_bresp_i, m_rresp_i, mem_addr[1:0]};

  // ---------------- assertions ----------------
  // No bus request is issued while in WFI.
  `SVA_ASSERT_IMP(a_no_req_in_wfi, clk_i, rst_ni, wfi_q && astate_q == A_IDLE, !m_arvalid_o && !m_awvalid_o)
  // An acknowledged core stays in WFI until idle_req is withdrawn.
  `SVA_ASSERT_IMP(a_ack_implies_wfi, clk_i, rst_ni, idle_ack_q, wfi_q)
  `SVA_COVER(c_wfi_enter, clk_i, rst_ni, astate_q == A_DONE && wfi_hit)
endmodule
