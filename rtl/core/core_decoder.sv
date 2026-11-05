// RV32IM + Zicsr + Zifencei instruction decoder (machine mode only).
// Pure combinational. CSR address legality is checked separately (core_csr).
module core_decoder
  import riscv_pkg::*;
(
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  assign imm_i = {{20{instr[31]}}, instr[31:20]};
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_u = {instr[31:12], 12'b0};
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    ctrl          = '0;
    ctrl.alu_op   = ALU_ADD;
    ctrl.opa_sel  = OPA_RS1;
    ctrl.opb_sel  = OPB_IMM;
    ctrl.rs1      = instr[19:15];
    ctrl.rs2      = instr[24:20];
    ctrl.rd       = instr[11:7];
    ctrl.funct3   = funct3;
    ctrl.illegal  = 1'b0;

    unique case (opcode)
      OPC_LUI: begin
        ctrl.alu_op  = ALU_PASSB;
        ctrl.opa_sel = OPA_ZERO;
        ctrl.imm     = imm_u;
        ctrl.rd_we   = 1'b1;
      end

      OPC_AUIPC: begin
        ctrl.opa_sel = OPA_PC;
        ctrl.imm     = imm_u;
        ctrl.rd_we   = 1'b1;
      end

      OPC_JAL: begin
        ctrl.is_jal  = 1'b1;
        ctrl.opa_sel = OPA_PC;
        ctrl.opb_sel = OPB_FOUR;
        ctrl.imm     = imm_j;
        ctrl.rd_we   = 1'b1;
      end

      OPC_JALR: begin
        ctrl.is_jalr  = 1'b1;
        ctrl.opa_sel  = OPA_PC;
        ctrl.opb_sel  = OPB_FOUR;
        ctrl.imm      = imm_i;
        ctrl.rs1_used = 1'b1;
        ctrl.rd_we    = 1'b1;
        ctrl.illegal  = (funct3 != 3'b000);
      end

      OPC_BRANCH: begin
        ctrl.is_branch = 1'b1;
        ctrl.imm       = imm_b;
        ctrl.rs1_used  = 1'b1;
        ctrl.rs2_used  = 1'b1;
        ctrl.illegal   = (funct3 == 3'b010) || (funct3 == 3'b011);
      end

      OPC_LOAD: begin
        ctrl.is_load  = 1'b1;
        ctrl.imm      = imm_i;
        ctrl.rs1_used = 1'b1;
        ctrl.rd_we    = 1'b1;
        ctrl.illegal  = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
      end

      OPC_STORE: begin
        ctrl.is_store = 1'b1;
        ctrl.imm      = imm_s;
        ctrl.rs1_used = 1'b1;
        ctrl.rs2_used = 1'b1;
        ctrl.illegal  = (funct3[2] == 1'b1) || (funct3 == 3'b011);
      end

      OPC_OP_IMM: begin
        ctrl.imm      = imm_i;
        ctrl.rs1_used = 1'b1;
        ctrl.rd_we    = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;
          3'b010: ctrl.alu_op = ALU_SLT;
          3'b011: ctrl.alu_op = ALU_SLTU;
          3'b100: ctrl.alu_op = ALU_XOR;
          3'b110: ctrl.alu_op = ALU_OR;
          3'b111: ctrl.alu_op = ALU_AND;
          3'b001: begin
            ctrl.alu_op  = ALU_SLL;
            ctrl.illegal = (funct7 != 7'b0000000);
          end
          3'b101: begin
            ctrl.alu_op  = funct7[5] ? ALU_SRA : ALU_SRL;
            ctrl.illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
          end
          default: ;
        endcase
      end

      OPC_OP: begin
        ctrl.opb_sel  = OPB_RS2;
        ctrl.rs1_used = 1'b1;
        ctrl.rs2_used = 1'b1;
        ctrl.rd_we    = 1'b1;
        if (funct7 == 7'b0000001) begin
          ctrl.is_mul = !funct3[2];
          ctrl.is_div =  funct3[2];
        end else if (funct7 == 7'b0000000) begin
          unique case (funct3)
            3'b000: ctrl.alu_op = ALU_ADD;
            3'b001: ctrl.alu_op = ALU_SLL;
            3'b010: ctrl.alu_op = ALU_SLT;
            3'b011: ctrl.alu_op = ALU_SLTU;
            3'b100: ctrl.alu_op = ALU_XOR;
            3'b101: ctrl.alu_op = ALU_SRL;
            3'b110: ctrl.alu_op = ALU_OR;
            3'b111: ctrl.alu_op = ALU_AND;
            default: ;
          endcase
        end else if (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101)) begin
          ctrl.alu_op = (funct3 == 3'b000) ? ALU_SUB : ALU_SRA;
        end else begin
          ctrl.illegal = 1'b1;
        end
      end

      OPC_MISC_MEM: begin
        // FENCE: all field values are legal (hints / TSO / PAUSE); executed as a nop
        // because the core issues data accesses strictly in order.
        // FENCE.I: only opcode+funct3 are decoded (other fields reserved/ignored).
        if (funct3 == 3'b001)      ctrl.is_fence_i = 1'b1;
        else if (funct3 != 3'b000) ctrl.illegal    = 1'b1;
      end

      OPC_SYSTEM: begin
        if (funct3 == 3'b000) begin
          unique case (instr)
            32'h0000_0073: ctrl.is_ecall  = 1'b1;
            32'h0010_0073: ctrl.is_ebreak = 1'b1;
            32'h3020_0073: ctrl.is_mret   = 1'b1;
            32'h1050_0073: ctrl.is_wfi    = 1'b1;
            default:       ctrl.illegal   = 1'b1;
          endcase
        end else if (funct3 == 3'b100) begin
          ctrl.illegal = 1'b1;
        end else begin
          ctrl.is_csr   = 1'b1;
          ctrl.rd_we    = 1'b1;
          ctrl.imm      = {27'b0, instr[19:15]};       // zimm
          ctrl.rs1_used = !funct3[2];
          // CSRRW/CSRRWI always write; CSRRS/C(I) write only if rs1/uimm != 0
          ctrl.csr_write = (funct3[1:0] == 2'b01) || (instr[19:15] != 5'd0);
        end
      end

      default: ctrl.illegal = 1'b1;
    endcase

    // Compressed / non-32-bit encodings are illegal (no C extension)
    if (instr[1:0] != 2'b11) ctrl.illegal = 1'b1;

    if (ctrl.illegal) begin
      ctrl.rd_we    = 1'b0;
      ctrl.rs1_used = 1'b0;
      ctrl.rs2_used = 1'b0;
      ctrl.is_load  = 1'b0;
      ctrl.is_store = 1'b0;
      ctrl.is_branch = 1'b0;
      ctrl.is_jal   = 1'b0;
      ctrl.is_jalr  = 1'b0;
      ctrl.is_mul   = 1'b0;
      ctrl.is_div   = 1'b0;
      ctrl.is_csr   = 1'b0;
      ctrl.csr_write = 1'b0;
      ctrl.is_fence_i = 1'b0;
    end
    if (ctrl.rd == 5'd0) ctrl.rd_we = 1'b0;
  end

endmodule
