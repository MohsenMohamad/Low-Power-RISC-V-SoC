// pmu_env_types.svh - types shared by the PMU environment

// Reference-model view of PD_CPU. RUN/IDLE/SLEEP/DEEP are the stable CPU
// power states from SPEC.md; PD/PU are the sequencing phases between them.
typedef enum {
  PMU_RESET,   // PD_AON reset asserted
  PMU_RUN,
  PMU_IDLE,
  PMU_PD,      // power-down sequence in progress
  PMU_SLEEP,
  PMU_DEEP,    // DEEP_SLEEP
  PMU_PU       // power-up sequence in progress (wake or cold boot)
} pmu_state_e;

// Why a bus access is expected to fail
typedef enum {
  PMU_ERR_NONE,
  PMU_ERR_UNMAPPED,     // no register at that address           -> DECERR
  PMU_ERR_RESERVED,     // reserved field value                  -> SLVERR
  PMU_ERR_DOMAIN_OFF    // register in a domain that is not up   -> SLVERR
} pmu_err_reason_e;

// Individual control-pin events seen on the power interface
typedef enum {
  EV_CLK_ON, EV_CLK_OFF,
  EV_ISO_ON, EV_ISO_OFF,
  EV_RST_ASSERT, EV_RST_RELEASE,
  EV_RET_ON, EV_RET_OFF,
  EV_PWR_ON, EV_PWR_OFF
} pmu_pin_ev_e;

function automatic bit pmu_is_stable(pmu_state_e s);
  return s inside {PMU_RUN, PMU_IDLE, PMU_SLEEP, PMU_DEEP};
endfunction

// Completed transition between stable states (or a DVFS change in IDLE),
// published by the scoreboard for coverage.
class pmu_trans_item extends uvm_sequence_item;
  pmu_state_e  from_st, to_st;
  bit          is_dvfs;        // DVFS mux change (from_st == to_st == IDLE)
  bit [1:0]    opp_from, opp_to;
  int unsigned dwell_cycles;   // cycles spent in from_st
  bit          wake_during_pd; // wake request already pending when OFF was reached
  realtime     t;
  `uvm_object_utils(pmu_trans_item)
  function new(string name = "pmu_trans_item"); super.new(name); endfunction
  function string convert2string();
    if (is_dvfs) return $sformatf("DVFS OPP%0d -> OPP%0d @%0t", opp_from, opp_to, t);
    return $sformatf("%s -> %s (dwell %0d) @%0t", from_st.name(), to_st.name(), dwell_cycles, t);
  endfunction
endclass

// Bus access classified by the scoreboard, published for coverage.
class pmu_bus_item extends uvm_sequence_item;
  axi_lite_item     tr;
  int               reg_idx;     // index into pmu_env_cfg::reg_names, -1 = unmapped
  bit               in_pd_cpu;
  pmu_state_e       st;          // model state when the request was accepted
  pmu_err_reason_e  reason;
  axi_lite_resp_e   exp_resp;
  bit               boundary;    // domain changed state during the access
  `uvm_object_utils(pmu_bus_item)
  function new(string name = "pmu_bus_item"); super.new(name); endfunction
endclass
