// pmu_coverage.svh - PMU functional coverage
//
//   cg_trans : full power-state transition matrix (from x to), with the
//              transitions the PMU must never make as illegal bins
//   cg_dvfs  : DVFS operating points and every OPP-to-OPP change
//   cg_bus   : register x direction x response, error reasons, and accesses
//              to PD_CPU registers in every power state
// Register field values are covered inside the RAL (pmu_ral_pkg, cg_vals).

`uvm_analysis_imp_decl(_trans)
`uvm_analysis_imp_decl(_bus)

class pmu_coverage extends uvm_component;
  `uvm_component_utils(pmu_coverage)

  uvm_analysis_imp_trans #(pmu_trans_item, pmu_coverage) trans_imp;
  uvm_analysis_imp_bus   #(pmu_bus_item,   pmu_coverage) bus_imp;

  pmu_trans_item tr;
  pmu_bus_item   bi;

  covergroup cg_trans;
    option.per_instance = 1;
    cp_from: coverpoint tr.from_st {
      bins reset = {PMU_RESET}; bins run = {PMU_RUN}; bins idle = {PMU_IDLE};
      bins sleep = {PMU_SLEEP}; bins deep = {PMU_DEEP};
    }
    cp_to: coverpoint tr.to_st {
      bins run = {PMU_RUN}; bins idle = {PMU_IDLE}; bins sleep = {PMU_SLEEP}; bins deep = {PMU_DEEP};
    }
    x_matrix: cross cp_from, cp_to {
      // legal transitions (all must be hit)
      //   reset->run (cold boot), run->{idle,sleep,deep}, {idle,sleep,deep}->run
      illegal_bins reset_to_lp  = binsof(cp_from.reset) && !binsof(cp_to.run);
      illegal_bins lp_to_lp     = binsof(cp_from) intersect {PMU_IDLE, PMU_SLEEP, PMU_DEEP} &&
                                  binsof(cp_to)   intersect {PMU_IDLE, PMU_SLEEP, PMU_DEEP};
      ignore_bins  run_to_run   = binsof(cp_from.run) && binsof(cp_to.run);
    }
    cp_dwell: coverpoint tr.dwell_cycles iff (tr.from_st != PMU_RESET) {
      bins short_d = {[0:15]}; bins mid = {[16:127]}; bins long_d = {[128:$]};
    }
    x_from_dwell: cross cp_from, cp_dwell {
      ignore_bins reset = binsof(cp_from.reset);
    }
    cp_wake_during_pd: coverpoint tr.wake_during_pd iff (tr.to_st inside {PMU_SLEEP, PMU_DEEP}) {
      bins normal = {0}; bins early_wake = {1};
    }
    x_lp_early: cross cp_to, cp_wake_during_pd {
      ignore_bins na = binsof(cp_to) intersect {PMU_RUN, PMU_IDLE};
    }
    cp_opp_at: coverpoint tr.opp_to { bins opp[] = {[0:2]}; illegal_bins reserved = {3}; }
    x_state_opp: cross cp_to, cp_opp_at;
  endgroup

  covergroup cg_dvfs;
    option.per_instance = 1;
    cp_from: coverpoint tr.opp_from { bins opp[] = {[0:2]}; illegal_bins reserved = {3}; }
    cp_to:   coverpoint tr.opp_to   { bins opp[] = {[0:2]}; illegal_bins reserved = {3}; }
    x_change: cross cp_from, cp_to {
      ignore_bins same = (binsof(cp_from) intersect {0} && binsof(cp_to) intersect {0}) ||
                         (binsof(cp_from) intersect {1} && binsof(cp_to) intersect {1}) ||
                         (binsof(cp_from) intersect {2} && binsof(cp_to) intersect {2});
    }
  endgroup

  covergroup cg_bus;
    option.per_instance = 1;
    cp_reg: coverpoint bi.reg_idx {
      bins regs[] = {[0:11]};
      bins unmapped = {-1};
    }
    cp_kind: coverpoint bi.tr.kind;
    cp_resp: coverpoint bi.tr.resp {
      bins okay = {AXI_OKAY}; bins slverr = {AXI_SLVERR}; bins decerr = {AXI_DECERR};
      illegal_bins exokay = {AXI_EXOKAY};
    }
    cp_reason: coverpoint bi.reason;
    x_reg_kind: cross cp_reg, cp_kind;
    x_reason_kind: cross cp_reason, cp_kind;
    x_reason_resp: cross cp_reason, cp_resp {
      ignore_bins impossible = (binsof(cp_reason) intersect {PMU_ERR_NONE} && !binsof(cp_resp.okay)) ||
                               (binsof(cp_reason) intersect {PMU_ERR_UNMAPPED} && !binsof(cp_resp.decerr)) ||
                               (binsof(cp_reason) intersect {PMU_ERR_RESERVED, PMU_ERR_DOMAIN_OFF} && !binsof(cp_resp.slverr));
    }
    // PD_CPU register accesses in every power state of PD_CPU
    cp_pd_state: coverpoint bi.st iff (bi.in_pd_cpu) {
      bins run = {PMU_RUN}; bins idle = {PMU_IDLE}; bins pd = {PMU_PD};
      bins sleep = {PMU_SLEEP}; bins deep = {PMU_DEEP}; bins pu = {PMU_PU};
    }
    x_pd_state_kind: cross cp_pd_state, cp_kind;
    cp_boundary: coverpoint bi.boundary iff (bi.in_pd_cpu) { bins inside_state = {0}; bins at_boundary = {1}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    trans_imp = new("trans_imp", this);
    bus_imp   = new("bus_imp", this);
    cg_trans  = new();
    cg_dvfs   = new();
    cg_bus    = new();
  endfunction

  function void write_trans(pmu_trans_item t);
    tr = t;
    if (t.is_dvfs) cg_dvfs.sample();
    else           cg_trans.sample();
  endfunction

  function void write_bus(pmu_bus_item b);
    bi = b;
    cg_bus.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf({"\n  power-state transitions : %0.2f%%\n  DVFS                    : %0.2f%%\n",
                                "  bus / error responses   : %0.2f%%"},
                               cg_trans.get_inst_coverage(), cg_dvfs.get_inst_coverage(),
                               cg_bus.get_inst_coverage()), UVM_LOW)
  endfunction

endclass
