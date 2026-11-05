// RV32IM core package: encodings, CSR addresses, trap causes, pipeline types.
package riscv_pkg;

  // ---------------------------------------------------------------------------
  // Opcodes
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPC_LOAD     = 7'b0000011;
  localparam logic [6:0] OPC_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OPC_OP_IMM   = 7'b0010011;
  localparam logic [6:0] OPC_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPC_STORE    = 7'b0100011;
  localparam logic [6:0] OPC_OP       = 7'b0110011;
  localparam logic [6:0] OPC_LUI      = 7'b0110111;
  localparam logic [6:0] OPC_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPC_JALR     = 7'b1100111;
  localparam logic [6:0] OPC_JAL      = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM   = 7'b1110011;

  // ---------------------------------------------------------------------------
  // CSR addresses
  // ---------------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS    = 12'h300;
  localparam logic [11:0] CSR_MISA       = 12'h301;
  localparam logic [11:0] CSR_MIE        = 12'h304;
  localparam logic [11:0] CSR_MTVEC      = 12'h305;
  localparam logic [11:0] CSR_MSTATUSH   = 12'h310;
  localparam logic [11:0] CSR_MCOUNTINH  = 12'h320;
  localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
  localparam logic [11:0] CSR_MEPC       = 12'h341;
  localparam logic [11:0] CSR_MCAUSE     = 12'h342;
  localparam logic [11:0] CSR_MTVAL      = 12'h343;
  localparam logic [11:0] CSR_MIP        = 12'h344;
  localparam logic [11:0] CSR_MCYCLE     = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET   = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH    = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH  = 12'hB82;
  localparam logic [11:0] CSR_CYCLE      = 12'hC00;
  localparam logic [11:0] CSR_INSTRET    = 12'hC02;
  localparam logic [11:0] CSR_CYCLEH     = 12'hC80;
  localparam logic [11:0] CSR_INSTRETH   = 12'hC82;
  localparam logic [11:0] CSR_MVENDORID  = 12'hF11;
  localparam logic [11:0] CSR_MARCHID    = 12'hF12;
  localparam logic [11:0] CSR_MIMPID     = 12'hF13;
  localparam logic [11:0] CSR_MHARTID    = 12'hF14;
  localparam logic [11:0] CSR_MCONFIGPTR = 12'hF15;
  // Custom machine-mode read/write CSR: cache maintenance (see doc/CPU.md).
  localparam logic [11:0] CSR_MCACHECTL  = 12'h7C0;

  // misa: MXL=1 (32-bit), extensions I and M.
  localparam logic [31:0] MISA_VALUE = 32'h4000_1100;

  // mstatus bit positions
  localparam int MSTATUS_MIE  = 3;
  localparam int MSTATUS_MPIE = 7;

  // Interrupt bit positions (mip/mie)
  localparam int IRQ_MSI = 3;
  localparam int IRQ_MTI = 7;
  localparam int IRQ_MEI = 11;

  // ---------------------------------------------------------------------------
  // Trap causes
  // ---------------------------------------------------------------------------
  localparam logic [4:0] EXC_INSTR_MISALIGNED = 5'd0;
  localparam logic [4:0] EXC_INSTR_ACCESS     = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL          = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT       = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGNED  = 5'd4;
  localparam logic [4:0] EXC_LOAD_ACCESS      = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGNED = 5'd6;
  localparam logic [4:0] EXC_STORE_ACCESS     = 5'd7;
  localparam logic [4:0] EXC_ECALL_M          = 5'd11;

  // ---------------------------------------------------------------------------
  // Decoded control
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR,
    ALU_SRL, ALU_SRA, ALU_OR, ALU_AND, ALU_PASSB
  } alu_op_e;

  typedef enum logic [1:0] { OPA_RS1, OPA_PC, OPA_ZERO } opa_sel_e;
  typedef enum logic [1:0] { OPB_RS2, OPB_IMM, OPB_FOUR } opb_sel_e;

  typedef struct packed {
    alu_op_e     alu_op;
    opa_sel_e    opa_sel;
    opb_sel_e    opb_sel;
    logic [31:0] imm;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic        rs1_used;
    logic        rs2_used;
    logic        rd_we;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic [2:0]  funct3;
    logic        is_load;
    logic        is_store;
    logic        is_mul;
    logic        is_div;
    logic        is_csr;
    logic        csr_write;    // CSR instruction actually writes the CSR
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_wfi;
    logic        is_fence_i;
    logic        illegal;
  } ctrl_t;

  // Exception carried down the pipeline
  typedef struct packed {
    logic        valid;
    logic [4:0]  cause;
    logic [31:0] tval;
  } exc_t;

endpackage
