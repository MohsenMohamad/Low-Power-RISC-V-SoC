// White-box assertions and cover properties for dbg_trace (bound into every
// instance): trigger behaviour, freeze-on-error, capture gating, CPU port
// contract, FIFO bounds.
module dbg_trace_sva (
  input logic       clk_cpu_i,
  input logic       rst_c_n,
  input logic [1:0] cst_q,
  input logic       frozen_q,
  input logic       capturing,
  input logic       start_hit,
  input logic       stop_hit,
  input logic       en_c,
  input logic       clr_c,
  input logic       exc,
  input logic       frz_exc_c,
  input logic       frz_req_c,
  input logic       frz_req_prev_q,
  input logic [2:0] fcnt_q,
  input logic       f_ovf,
  input logic       ret_valid_i,
  input logic       trap_valid_i,
  input logic       v_ret,
  input logic       v_trap,
  input logic       v_pwr,
  input logic       pwr_evt,
  input logic [1:0] start_sel_q,
  input logic [1:0] stop_sel_q,
  input logic [31:0] wcnt_q
);
  localparam logic [1:0] C_IDLE = 2'd0, C_ARMED = 2'd1, C_ACTIVE = 2'd2, C_STOPPED = 2'd3;
  default clocking cb @(posedge clk_cpu_i); endclocking
  default disable iff (!rst_c_n);

  // CPU port contract (assumption on the CPU, checked here)
  m_flush: assert property (trap_valid_i |=> !ret_valid_i);

  // capture gating
  a_no_cap_frozen:  assert property (frozen_q |-> !capturing);
  a_no_cap_stopped: assert property (cst_q == C_STOPPED |-> !capturing);
  a_no_cap_idle:    assert property (cst_q == C_IDLE |-> !capturing);
  a_no_cap_dis:     assert property (!en_c |-> !capturing);
  a_ret_logged:     assert property (capturing && ret_valid_i |-> v_ret);

  // triggers
  a_start: assert property (en_c && !clr_c && !frozen_q && cst_q == C_ARMED && start_hit && !stop_hit
                            |=> cst_q == C_ACTIVE);
  a_start_stop: assert property (en_c && !clr_c && !frozen_q && cst_q == C_ARMED && start_hit && stop_hit
                                 |=> cst_q == C_STOPPED);
  a_stop:  assert property (en_c && !clr_c && !frozen_q && cst_q == C_ACTIVE && stop_hit
                            |=> cst_q == C_STOPPED);
  a_armed_wait: assert property (en_c && !clr_c && cst_q == C_ARMED && !start_hit |=> cst_q == C_ARMED);
  a_stopped_sticky: assert property (en_c && !clr_c && cst_q == C_STOPPED |=> cst_q == C_STOPPED);

  // freeze on error
  a_frz_exc: assert property (!clr_c && exc && frz_exc_c |=> frozen_q);
  a_frz_err: assert property (!clr_c && frz_req_c && !frz_req_prev_q |=> frozen_q);
  a_frz_sticky: assert property (frozen_q && !clr_c |=> frozen_q);
  a_frz_no_new: assert property (frozen_q && fcnt_q == 0 && !clr_c |=> $stable(wcnt_q) || clr_c);

  // FIFO bound: never overflows under the port contract
  a_fifo: assert property (fcnt_q <= 3'd4 && !f_ovf);

  // coverage
  c_start_none: cover property (cst_q == C_ARMED && start_sel_q == 2'd0 ##1 cst_q == C_ACTIVE);
  c_start_pc:   cover property (cst_q == C_ARMED && start_sel_q == 2'd1 ##1 cst_q == C_ACTIVE);
  c_start_exc:  cover property (cst_q == C_ARMED && start_sel_q == 2'd2 ##1 cst_q == C_ACTIVE);
  c_start_pwr:  cover property (cst_q == C_ARMED && start_sel_q == 2'd3 ##1 cst_q == C_ACTIVE);
  c_stop_pc:    cover property (cst_q == C_ACTIVE && stop_sel_q == 2'd1 ##1 cst_q == C_STOPPED);
  c_stop_exc:   cover property (cst_q == C_ACTIVE && stop_sel_q == 2'd2 ##1 cst_q == C_STOPPED);
  c_stop_pwr:   cover property (cst_q == C_ACTIVE && stop_sel_q == 2'd3 ##1 cst_q == C_STOPPED);
  c_frz_exc:    cover property (!frozen_q && exc && frz_exc_c ##1 frozen_q);
  c_frz_err:    cover property (!frozen_q && frz_req_c && !frz_req_prev_q ##1 frozen_q);
  c_ret_trap:   cover property (v_ret && v_trap);
  c_pwr_entry:  cover property (v_pwr);
  c_fifo2:      cover property (fcnt_q >= 3'd2);
  c_wrap:       cover property (wcnt_q == 32'd32);
  c_clear:      cover property (clr_c && wcnt_q != 0);
endmodule

bind dbg_trace dbg_trace_sva u_trace_sva (.*);
