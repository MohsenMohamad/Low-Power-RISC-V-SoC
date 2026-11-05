// Micro-architectural functional coverage (bound into the design, sim only).
// Collected with Verilator --coverage-user and reported by scripts/cov_report.py.

module core_cov_probe (
  input logic        clk,
  input logic        rst_n,
  input logic        id_hazard,
  input logic        ex_stall,
  input logic        mem_stall,
  input logic        wb_wait_mem,
  input logic        wb_wait_sys,
  input logic        ex_redirect,
  input logic        wb_flush,
  input logic        irq_take_now,
  input logic        irq_take,
  input logic        wfi_sleep_q,
  input logic        ex_div_wait,
  input logic        div_start,
  input logic [31:0] ex_rs1,
  input logic [31:0] ex_rs2,
  input logic        ex_valid,
  input logic        mem_valid,
  input logic        wb_valid,
  input riscv_pkg::ctrl_t ex_ctrl,
  input riscv_pkg::ctrl_t mem_ctrl,
  input riscv_pkg::ctrl_t wb_ctrl,
  input logic        dmem_req_o,
  input logic        dmem_gnt_i,
  input logic        mem_issue_ok,
  input logic        mem_needs_req,
  input logic        imem_req_o,
  input logic        imem_gnt_i,
  input logic        imem_rvalid_i,
  input logic        redirect,
  input logic        f_idle
);
  // Forwarding paths actually used by an EX instruction
  wire fwd_mem_rs1 = ex_valid && ex_ctrl.rs1_used && mem_valid && mem_ctrl.rd_we && mem_ctrl.rd == ex_ctrl.rs1;
  wire fwd_mem_rs2 = ex_valid && ex_ctrl.rs2_used && mem_valid && mem_ctrl.rd_we && mem_ctrl.rd == ex_ctrl.rs2;
  wire fwd_wb_rs1  = ex_valid && ex_ctrl.rs1_used && wb_valid && wb_ctrl.rd_we && wb_ctrl.rd == ex_ctrl.rs1 && !fwd_mem_rs1;
  wire fwd_wb_rs2  = ex_valid && ex_ctrl.rs2_used && wb_valid && wb_ctrl.rd_we && wb_ctrl.rd == ex_ctrl.rs2 && !fwd_mem_rs2;
  wire fwd_wb_load = (fwd_wb_rs1 || fwd_wb_rs2) && wb_ctrl.is_load;

  cp_load_use_stall:     cover property (@(posedge clk) disable iff (!rst_n) id_hazard && ex_ctrl.is_load);
  cp_csr_use_stall:      cover property (@(posedge clk) disable iff (!rst_n) id_hazard && ex_ctrl.is_csr);
  cp_fwd_mem_rs1:        cover property (@(posedge clk) disable iff (!rst_n) fwd_mem_rs1);
  cp_fwd_mem_rs2:        cover property (@(posedge clk) disable iff (!rst_n) fwd_mem_rs2);
  cp_fwd_wb_rs1:         cover property (@(posedge clk) disable iff (!rst_n) fwd_wb_rs1);
  cp_fwd_wb_rs2:         cover property (@(posedge clk) disable iff (!rst_n) fwd_wb_rs2);
  cp_fwd_wb_load:        cover property (@(posedge clk) disable iff (!rst_n) fwd_wb_load);
  cp_fwd_while_stalled:  cover property (@(posedge clk) disable iff (!rst_n) (fwd_wb_rs1 || fwd_wb_rs2) && mem_stall && !wb_wait_mem);
  cp_store_after_load:   cover property (@(posedge clk) disable iff (!rst_n) mem_valid && mem_ctrl.is_store && wb_valid && wb_ctrl.is_load);
  cp_mem_blocked_by_wb:  cover property (@(posedge clk) disable iff (!rst_n) mem_needs_req && !mem_issue_ok);
  cp_dmem_backpressure:  cover property (@(posedge clk) disable iff (!rst_n) dmem_req_o && !dmem_gnt_i);
  cp_wb_wait_mem:        cover property (@(posedge clk) disable iff (!rst_n) wb_wait_mem);
  cp_wb_wait_sys:        cover property (@(posedge clk) disable iff (!rst_n) wb_wait_sys);
  cp_branch_redirect:    cover property (@(posedge clk) disable iff (!rst_n) ex_redirect);
  cp_redirect_when_stall:cover property (@(posedge clk) disable iff (!rst_n) ex_valid && ex_ctrl.is_branch && ex_stall);
  cp_wb_flush:           cover property (@(posedge clk) disable iff (!rst_n) wb_flush);
  cp_flush_and_branch:   cover property (@(posedge clk) disable iff (!rst_n) wb_flush && ex_valid && (ex_ctrl.is_branch || ex_ctrl.is_jal || ex_ctrl.is_jalr));
  cp_flush_kills_div:    cover property (@(posedge clk) disable iff (!rst_n) wb_flush && ex_div_wait);
  cp_irq_taken:          cover property (@(posedge clk) disable iff (!rst_n) irq_take_now);
  cp_irq_drain_wait:     cover property (@(posedge clk) disable iff (!rst_n) irq_take && !irq_take_now && (ex_valid || mem_valid || wb_valid));
  cp_irq_wakes_wfi:      cover property (@(posedge clk) disable iff (!rst_n) $fell(wfi_sleep_q));
  cp_wfi_sleep:          cover property (@(posedge clk) disable iff (!rst_n) wfi_sleep_q && f_idle);
  cp_div_by_zero:        cover property (@(posedge clk) disable iff (!rst_n) div_start && ex_rs2 == 32'd0);
  cp_div_overflow:       cover property (@(posedge clk) disable iff (!rst_n) div_start && ex_rs1 == 32'h8000_0000 && ex_rs2 == 32'hFFFF_FFFF && !ex_ctrl.funct3[0]);
  cp_div_neg_neg:        cover property (@(posedge clk) disable iff (!rst_n) div_start && ex_rs1[31] && ex_rs2[31] && !ex_ctrl.funct3[0]);
  cp_div_stall:          cover property (@(posedge clk) disable iff (!rst_n) ex_div_wait);
  cp_mul_neg:            cover property (@(posedge clk) disable iff (!rst_n) ex_valid && ex_ctrl.is_mul && ex_rs1[31] && ex_rs2[31]);
  cp_fetch_backpressure: cover property (@(posedge clk) disable iff (!rst_n) imem_req_o && !imem_gnt_i);
  cp_fetch_discard:      cover property (@(posedge clk) disable iff (!rst_n) redirect && !f_idle);
  cp_fetch_resp_on_redir:cover property (@(posedge clk) disable iff (!rst_n) redirect && imem_rvalid_i);
endmodule

module dcache_cov_probe (
  input logic       clk,
  input logic       rst_n,
  input logic [4:0] state_q,
  input logic       hit,
  input logic       rq_we_q,
  input logic       accept,
  input logic       maint_req_i,
  input logic       maint_inval_i,
  input logic       fl_line_dirty,
  input logic       wb_err_q,
  input logic       err_o,
  input logic       rvalid_o,
  input logic       victim_sel,
  input logic       m_awvalid,
  input logic       m_awready,
  input logic       m_wvalid,
  input logic       m_wready
);
  // state encoding follows dcache.sv state_e
  localparam logic [4:0] LOOKUP = 5'd1, WB_RD = 5'd2, WB_W = 5'd3, RF_AR = 5'd5, UC_AR = 5'd8,
                         UC_AW = 5'd10, FL_SCAN = 5'd12, FL_DONE = 5'd14;
  cp_load_hit:          cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && hit && !rq_we_q);
  cp_store_hit:         cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && hit && rq_we_q);
  cp_load_miss:         cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && !hit && !rq_we_q);
  cp_store_miss:        cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && !hit && rq_we_q);
  cp_hit_then_accept:   cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && hit && accept);
  cp_dirty_evict:       cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && !hit ##1 state_q == WB_RD);
  cp_evict_way1:        cover property (@(posedge clk) disable iff (!rst_n) state_q == LOOKUP && !hit && victim_sel);
  cp_uncached_read:     cover property (@(posedge clk) disable iff (!rst_n) state_q == UC_AR);
  cp_uncached_write:    cover property (@(posedge clk) disable iff (!rst_n) state_q == UC_AW);
  cp_aw_before_w:       cover property (@(posedge clk) disable iff (!rst_n) (state_q == WB_W) && m_awvalid && m_awready && !(m_wvalid && m_wready));
  cp_w_before_aw:       cover property (@(posedge clk) disable iff (!rst_n) (state_q == WB_W) && m_wvalid && m_wready && !(m_awvalid && m_awready));
  cp_maint_clean:       cover property (@(posedge clk) disable iff (!rst_n) state_q == FL_DONE && !maint_inval_i);
  cp_maint_flush:       cover property (@(posedge clk) disable iff (!rst_n) state_q == FL_DONE && maint_inval_i);
  cp_maint_dirty_line:  cover property (@(posedge clk) disable iff (!rst_n) state_q == FL_SCAN && fl_line_dirty);
  cp_resp_error:        cover property (@(posedge clk) disable iff (!rst_n) rvalid_o && err_o);
  cp_wb_error:          cover property (@(posedge clk) disable iff (!rst_n) wb_err_q);
  cp_refill_ar:         cover property (@(posedge clk) disable iff (!rst_n) state_q == RF_AR);
  wire unused = maint_req_i;
endmodule

module icache_cov_probe (
  input logic       clk,
  input logic       rst_n,
  input logic [2:0] state_q,
  input logic       hit,
  input logic       accept,
  input logic       inval_req_i,
  input logic       err_o,
  input logic       rvalid_o
);
  cp_hit:             cover property (@(posedge clk) disable iff (!rst_n) state_q == 3'd1 && hit);
  cp_miss:            cover property (@(posedge clk) disable iff (!rst_n) state_q == 3'd1 && !hit);
  cp_hit_then_accept: cover property (@(posedge clk) disable iff (!rst_n) state_q == 3'd1 && hit && accept);
  cp_uncached:        cover property (@(posedge clk) disable iff (!rst_n) state_q == 3'd5);
  cp_invalidate:      cover property (@(posedge clk) disable iff (!rst_n) state_q == 3'd0 && inval_req_i);
  cp_fetch_error:     cover property (@(posedge clk) disable iff (!rst_n) rvalid_o && err_o);
endmodule

bind core_top core_cov_probe u_core_cov (.*);
bind dcache   dcache_cov_probe u_dcache_cov (.state_q(state_q), .*);
bind icache   icache_cov_probe u_icache_cov (.state_q(state_q), .*);
