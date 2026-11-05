// pmu_scoreboard.svh - reference model of PMU power sequencing + bus checker
//
// Inputs
//   axi_imp : completed AXI4-Lite transactions (with handshake timestamps)
//   pwr_imp : power-interface snapshots (published on every change)
//
// Power checks (from pins only, so any PMU implementation can be checked)
//   * power-down order : clock gate -> isolation on -> reset assert
//                        -> [retention on, DEEP_SLEEP] -> switch off
//   * wake-up order    : switch on -> power_good -> [retention off]
//                        -> reset release -> isolation off -> clock on
//   * one control pin per clock edge during sequencing (strict order)
//   * IDLE entered only on WFI, left only on an enabled wake source
//   * DVFS mux changes only in IDLE, only to the programmed legal OPP, never
//     together with the clock enable, and a pending change completes in IDLE
//   * isolation clamps: isolated outputs == clamp value while isolation is on,
//     == raw domain outputs otherwise
//   * static invariants between gate / isolation / reset / switch / power_good
//
// Bus checks
//   * response code: DECERR for unmapped, SLVERR for reserved values and for
//     PD_CPU registers while PD_CPU is not RUNning, OKAY otherwise. An access
//     that overlaps a domain state change may legally get either response.
//   * read data of non-volatile PD_AON registers: by the RAL predictor
//     (check_on_read on the PMU map).
//   * read data of PD_CPU registers: by this scoreboard, which models their
//     loss on domain reset (not retained) and orders each access against the
//     reset using the bus timestamps.
//   * volatile registers (STATUS, WAKE_CAUSE, PD_COUNT): against the model.
//
// The register-specific parts are virtual functions so a derived scoreboard
// can adapt them to a different PMU register map via a factory override.

`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_pwr)

class pmu_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(pmu_scoreboard)

  uvm_analysis_imp_axi #(axi_lite_item, pmu_scoreboard) axi_imp;
  uvm_analysis_imp_pwr #(pwr_obs, pmu_scoreboard)       pwr_imp;
  uvm_analysis_port #(pmu_trans_item)                   trans_ap;
  uvm_analysis_port #(pmu_bus_item)                     bus_ap;

  pmu_env_cfg       cfg;
  pmu_reg_block     ral;
  pmu_state_tracker tracker;

  // ---------------- reference model state ----------------
  protected pmu_state_e  st = PMU_RESET;
  protected pmu_state_e  last_stable = PMU_RESET;
  protected longint unsigned stable_since_cyc;
  protected pmu_pin_ev_e exp_q[$];
  protected bit          mode_deep;
  protected bit          wake_seen;         // enabled wake source seen since entering low power
  protected bit          wake_seen_at_off;  // ... already when OFF was reached
  protected bit [7:0]    wake_bits_seen;
  protected bit          dvfs_pend_at_idle;
  protected pwr_obs      last;

  // register shadow (updated by OKAY writes)
  protected bit          sh_pd_en, sh_ret_en;
  protected bit [1:0]    sh_opp;
  protected bit [7:0]    sh_mask = 8'hFF;

  // volatile-register expectations
  protected bit [7:0]    cause_possible;   // bits that may be set in WAKE_CAUSE
  protected realtime     last_wake_t = -1;
  protected realtime     pd_done_t[$];     // times power-down completed

  // PD_CPU register contents (not retained across power-off)
  protected bit [31:0]   win_val[uvm_reg];
  protected bit [31:0]   win_before_reset[uvm_reg];
  protected realtime     last_dom_reset_t = -1;

  // history for correlating bus accesses with the domain state
  typedef struct {
    realtime    t;
    pmu_state_e st;
    pwr_obs     o;
  } hist_t;
  protected hist_t hist[$];

  protected uvm_reg all_regs[$];

  // ---------------- statistics ----------------
  int unsigned n_snapshots, n_clamp_checks, n_seq_steps, n_transitions, n_dvfs;
  int unsigned n_bus, n_bus_err_resp, n_boundary, n_status_checks;
  int unsigned n_fail;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axi_imp  = new("axi_imp", this);
    pwr_imp  = new("pwr_imp", this);
    trans_ap = new("trans_ap", this);
    bus_ap   = new("bus_ap", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    if (ral == null) `uvm_fatal("SB", "register model not set")
    ral.get_registers(all_regs);
    sh_mask = ral.WAKE_MASK.MASK.get_reset();
    sh_opp  = ral.DVFS.OPP.get_reset();
  endfunction

  // Error reporting that also counts (used for the self-check summary)
  protected function void fail(string id, string msg);
    n_fail++;
    `uvm_error(id, msg)
  endfunction

  // =========================================================================
  // Sequencing rules (override for a PMU with a different documented order)
  // =========================================================================
  virtual function void pd_sequence(bit deep, ref pmu_pin_ev_e q[$]);
    q.delete();
    q.push_back(EV_ISO_ON);
    q.push_back(EV_RST_ASSERT);
    if (deep) q.push_back(EV_RET_ON);
    q.push_back(EV_PWR_OFF);
  endfunction

  // Remaining power-up steps given the pins at the start of power-up
  virtual function void pu_sequence(pwr_obs o, ref pmu_pin_ev_e q[$]);
    q.delete();
    if (!o.pwr_en)   q.push_back(EV_PWR_ON);
    if (o.ret_en)    q.push_back(EV_RET_OFF);
    if (!o.dom_rst_n) q.push_back(EV_RST_RELEASE);
    if (o.iso_en)    q.push_back(EV_ISO_OFF);
    if (!o.clk_en)   q.push_back(EV_CLK_ON);
  endfunction

  // =========================================================================
  // Power interface
  // =========================================================================
  function void write_pwr(pwr_obs o);
    pwr_obs p = last;
    pmu_pin_ev_e evs[$];
    bit dvfs_chg;

    n_snapshots++;
    last = o;

    if (!o.rst_n) begin
      if (st != PMU_RESET) begin
        set_state(PMU_RESET, o);
        exp_q.delete();
        ral.reset();
        sh_pd_en = 0; sh_ret_en = 0;
        sh_opp  = ral.DVFS.OPP.get_reset();
        sh_mask = ral.WAKE_MASK.MASK.get_reset();
        cause_possible = 0;
        pd_done_t.delete();
        win_val.delete();
        win_before_reset.delete();
      end
      if (cfg.check_invariants) check_invariants(o);
      record(o);
      return;
    end

    // Reset release: cold boot brings PD_CPU up without a wake source
    if (p == null || !p.rst_n) begin
      set_state(PMU_PU, o);
      pu_sequence(o, exp_q);
      if (exp_q.size() == 0) set_state(PMU_RUN, o);
      record(o);
      return;
    end

    if (o.has_x) fail("SB_X", {"X/Z on a PMU power output: ", o.convert2string()});

    check_clamp(o);
    if (cfg.check_invariants) check_invariants(o);

    // Wake sources seen while in (or entering) a low-power state
    if (st inside {PMU_IDLE, PMU_PD, PMU_SLEEP, PMU_DEEP}) begin
      bit [7:0] hit = o.wake_irq & sh_mask;
      if (hit != 0) begin
        wake_seen = 1;
        wake_bits_seen |= hit;
      end
    end

    // Decode control-pin edges
    if (p.clk_en    != o.clk_en)    evs.push_back(o.clk_en    ? EV_CLK_ON      : EV_CLK_OFF);
    if (p.iso_en    != o.iso_en)    evs.push_back(o.iso_en    ? EV_ISO_ON      : EV_ISO_OFF);
    if (p.dom_rst_n != o.dom_rst_n) evs.push_back(o.dom_rst_n ? EV_RST_RELEASE : EV_RST_ASSERT);
    if (p.ret_en    != o.ret_en)    evs.push_back(o.ret_en    ? EV_RET_ON      : EV_RET_OFF);
    if (p.pwr_en    != o.pwr_en)    evs.push_back(o.pwr_en    ? EV_PWR_ON      : EV_PWR_OFF);
    dvfs_chg = (p.dvfs_sel != o.dvfs_sel);

    if (evs.size() > 1) begin
      string s = "";
      foreach (evs[i]) s = {s, " ", evs[i].name()};
      fail("SB_ORDER", $sformatf("%0d power controls changed on the same clock edge (%s) in %s: steps must be strictly ordered",
                                 evs.size(), s, st.name()));
    end

    if (dvfs_chg) check_dvfs(p, o, evs);

    foreach (evs[i]) process_event(evs[i], p, o);

    record(o);
  endfunction

  protected function void process_event(pmu_pin_ev_e ev, pwr_obs p, pwr_obs o);
    n_seq_steps++;
    if (ev == EV_RST_ASSERT) domain_reset(o);
    case (st)
      PMU_RUN: begin
        if (ev == EV_CLK_OFF) begin
          if (!(p.wfi || o.wfi))
            fail("SB_WFI", $sformatf("clock gated in RUN without WFI @%0t", o.t));
          wake_seen = 0;
          wake_bits_seen = 0;
          if (sh_pd_en) begin
            mode_deep = sh_ret_en;
            pd_sequence(mode_deep, exp_q);
            set_state(PMU_PD, o);
          end else begin
            dvfs_pend_at_idle = (sh_opp != o.dvfs_sel);
            set_state(PMU_IDLE, o);
          end
        end else begin
          fail("SB_ORDER", $sformatf("unexpected %s in RUN (power-down must start with the clock gate) @%0t",
                                     ev.name(), o.t));
        end
      end

      PMU_IDLE: begin
        if (ev == EV_CLK_ON) begin
          if (!wake_seen)
            fail("SB_WAKE", $sformatf("left IDLE without an enabled wake source (mask=0x%02h irq=0x%02h) @%0t",
                                      sh_mask, o.wake_irq, o.t));
          if (cfg.check_dvfs_done && dvfs_pend_at_idle && o.dvfs_sel != sh_opp)
            fail("SB_DVFS", $sformatf("DVFS change to OPP%0d pending at IDLE entry was not applied before wake (still OPP%0d)",
                                      sh_opp, o.dvfs_sel));
          note_wake(p, o);
          set_state(PMU_RUN, o);
        end else begin
          fail("SB_ORDER", $sformatf("unexpected %s in IDLE (only clock-on may follow) @%0t", ev.name(), o.t));
        end
      end

      PMU_PD, PMU_PU: begin
        expect_step(ev, o);
        if (exp_q.size() == 0) begin
          if (st == PMU_PD) begin
            wake_seen_at_off = wake_seen;
            pd_done_t.push_back(o.t);
            set_state(mode_deep ? PMU_DEEP : PMU_SLEEP, o);
          end else begin
            set_state(PMU_RUN, o);
          end
        end
      end

      PMU_SLEEP, PMU_DEEP: begin
        if (ev == EV_PWR_ON) begin
          if (!wake_seen)
            fail("SB_WAKE", $sformatf("power switched on in %s without an enabled wake source (mask=0x%02h irq=0x%02h) @%0t",
                                      st.name(), sh_mask, o.wake_irq, o.t));
          if ((st == PMU_DEEP) != o.ret_en)
            fail("SB_RET", $sformatf("retention is %0b while in %s", o.ret_en, st.name()));
          note_wake(p, o);
          pu_sequence(o, exp_q);
          set_state(PMU_PU, o);
        end else begin
          fail("SB_ORDER", $sformatf("unexpected %s in %s (only switch-on may follow) @%0t", ev.name(), st.name(), o.t));
        end
      end

      default: fail("SB_ORDER", $sformatf("unexpected %s in %s @%0t", ev.name(), st.name(), o.t));
    endcase
  endfunction

  // Compare one sequencing step with the head of the expected queue
  protected function void expect_step(pmu_pin_ev_e ev, pwr_obs o);
    int idx = -1;
    foreach (exp_q[i]) if (exp_q[i] == ev) begin idx = i; break; end
    if (idx == 0) begin
      exp_q.pop_front();
    end else begin
      string s = "";
      foreach (exp_q[i]) s = {s, " ", exp_q[i].name()};
      fail("SB_ORDER", $sformatf("%s: got %s, expected next %s (remaining:%s) @%0t",
                                 st.name(), ev.name(), exp_q.size() ? exp_q[0].name() : "<none>", s, o.t));
      // resynchronise: drop everything up to and including the event
      if (idx > 0) repeat (idx + 1) void'(exp_q.pop_front());
    end
    // Steps that need the supply to be good
    if (ev inside {EV_RET_OFF, EV_RST_RELEASE, EV_ISO_OFF, EV_CLK_ON} && !o.pwr_good)
      fail("SB_PGOOD", $sformatf("%s before power_good @%0t", ev.name(), o.t));
  endfunction

  protected function void check_dvfs(pwr_obs p, pwr_obs o, pmu_pin_ev_e evs[$]);
    pmu_trans_item tr;
    n_dvfs++;
    if (st != PMU_IDLE)
      fail("SB_DVFS", $sformatf("DVFS mux changed OPP%0d->OPP%0d in %s (allowed only in IDLE) @%0t",
                                p.dvfs_sel, o.dvfs_sel, st.name(), o.t));
    if (o.clk_en || (EV_CLK_ON inside {evs}))
      fail("SB_DVFS", $sformatf("DVFS mux changed while the clock is enabled @%0t", o.t));
    if (o.dvfs_sel >= cfg.n_opp)
      fail("SB_DVFS", $sformatf("DVFS mux set to reserved OPP%0d", o.dvfs_sel));
    else if (o.dvfs_sel != sh_opp)
      fail("SB_DVFS", $sformatf("DVFS mux set to OPP%0d, programmed OPP%0d", o.dvfs_sel, sh_opp));
    tr = pmu_trans_item::type_id::create("dvfs");
    tr.is_dvfs  = 1;
    tr.from_st  = st;
    tr.to_st    = st;
    tr.opp_from = p.dvfs_sel;
    tr.opp_to   = o.dvfs_sel;
    tr.t        = o.t;
    tracker.opp = o.dvfs_sel;
    `uvm_info("SB", tr.convert2string(), UVM_MEDIUM)
    trans_ap.write(tr);
  endfunction

  protected function void check_clamp(pwr_obs o);
    bit [`PWR_ISO_W-1:0] exp = o.iso_en ? cfg.iso_clamp : o.dom_out;
    n_clamp_checks++;
    if (o.dom_out_iso != exp)
      fail("SB_ISO", $sformatf("isolated outputs 0x%0h, expected 0x%0h (iso_en=%0b raw=0x%0h) @%0t",
                               o.dom_out_iso, exp, o.iso_en, o.dom_out, o.t));
  endfunction

  protected function void check_invariants(pwr_obs o);
    if (o.clk_en && (o.iso_en || !o.dom_rst_n || !o.pwr_en || !o.pwr_good))
      fail("SB_INV", {"domain clock enabled while isolated/in reset/unpowered: ", o.convert2string()});
    if (!o.iso_en && (!o.dom_rst_n || !o.pwr_en || !o.pwr_good))
      fail("SB_INV", {"isolation off while domain in reset/unpowered: ", o.convert2string()});
    if (o.ret_en && o.dom_rst_n)
      fail("SB_INV", {"retention enabled while domain out of reset: ", o.convert2string()});
    if (!o.pwr_en && o.dom_rst_n)
      fail("SB_INV", {"power switch off while domain reset released: ", o.convert2string()});
  endfunction

  protected function void note_wake(pwr_obs p, pwr_obs o);
    cause_possible |= wake_bits_seen | (o.wake_irq & sh_mask);
    last_wake_t = o.t;
  endfunction

  // PD_CPU reset: its registers return to their reset values
  protected function void domain_reset(pwr_obs o);
    win_before_reset = win_val;
    win_val.delete();
    last_dom_reset_t = o.t;
    ral.CPU_WIN.reset();
  endfunction

  protected function void set_state(pmu_state_e s, pwr_obs o);
    if (s == st) return;
    `uvm_info("SB", $sformatf("state %s -> %s @%0t", st.name(), s.name(), o.t), UVM_HIGH)
    if (pmu_is_stable(s) || (s == PMU_RESET)) begin
      if (pmu_is_stable(s)) begin
        pmu_trans_item tr = pmu_trans_item::type_id::create("tr");
        tr.from_st        = last_stable;
        tr.to_st          = s;
        tr.dwell_cycles   = int'(o.cycle - stable_since_cyc);
        tr.wake_during_pd = (s inside {PMU_SLEEP, PMU_DEEP}) && wake_seen_at_off;
        tr.opp_from       = o.dvfs_sel;
        tr.opp_to         = o.dvfs_sel;
        tr.t              = o.t;
        n_transitions++;
        `uvm_info("SB", tr.convert2string(), UVM_MEDIUM)
        trans_ap.write(tr);
      end
      last_stable      = s;
      stable_since_cyc = o.cycle;
    end
    st = s;
    if (tracker != null) tracker.set(s);
  endfunction

  protected function void record(pwr_obs o);
    hist_t h;
    h.t  = o.t;
    h.st = st;
    h.o  = o;
    hist.push_back(h);
    if (hist.size() > 512) void'(hist.pop_front());
  endfunction

  // Model history entries covering [t0, t1): the entry in force at t0 plus
  // every later entry before t1.
  protected function void window(realtime t0, realtime t1, ref hist_t w[$]);
    int first = -1;
    w.delete();
    for (int i = hist.size() - 1; i >= 0; i--)
      if (hist[i].t <= t0) begin first = i; break; end
    if (first < 0) first = 0;
    for (int i = first; i < hist.size(); i++)
      if (i == first || hist[i].t < t1) w.push_back(hist[i]);
  endfunction

  // =========================================================================
  // Bus
  // =========================================================================

  // Expected response for a register that exists and is reachable.
  virtual function axi_lite_resp_e reg_resp(uvm_reg rg, axi_lite_item t, ref pmu_err_reason_e why);
    why = PMU_ERR_NONE;
    if (rg == ral.DVFS && t.kind == AXI_WRITE && t.strb[0] && t.data[1:0] >= cfg.n_opp) begin
      why = PMU_ERR_RESERVED;
      return cfg.reserved_resp;
    end
    return AXI_OKAY;
  endfunction

  // Track writes that change sequencing behaviour.
  virtual function void update_shadow(uvm_reg rg, axi_lite_item t);
    if (!t.strb[0]) return;
    if (rg == ral.CTRL) begin
      sh_pd_en  = t.data[ral.CTRL.PD_EN.get_lsb_pos()];
      sh_ret_en = t.data[ral.CTRL.RET_EN.get_lsb_pos()];
    end else if (rg == ral.DVFS) begin
      sh_opp = t.data[1:0];
    end else if (rg == ral.WAKE_MASK) begin
      sh_mask = t.data[7:0];
    end else if (rg == ral.WAKE_CAUSE) begin
      cause_possible &= ~t.data[7:0];
    end
  endfunction

  function void write_axi(axi_lite_item t);
    pmu_bus_item     b = pmu_bus_item::type_id::create("bus");
    uvm_reg          rg;
    hist_t           w[$];
    bit              any_run, any_off;
    axi_lite_resp_e  exp;
    pmu_err_reason_e why = PMU_ERR_NONE;

    n_bus++;
    if (t.resp != AXI_OKAY) n_bus_err_resp++;
    rg = ral.default_map.get_reg_by_offset(t.addr, t.kind == AXI_READ);
    window(t.t_req, t.t_resp, w);
    foreach (w[i]) begin
      if (w[i].st == PMU_RUN) any_run = 1;
      else                    any_off = 1;
    end

    b.tr        = t;
    b.st        = w.size() ? w[0].st : st;
    b.reg_idx   = -1;
    b.in_pd_cpu = 0;
    foreach (all_regs[i]) if (all_regs[i] == rg) b.reg_idx = i;

    if (rg == null) begin
      why = PMU_ERR_UNMAPPED;
      exp = cfg.unmapped_resp;
    end else if (ral.in_pd_cpu(rg)) begin
      b.in_pd_cpu = 1;
      if (any_run && any_off) begin
        b.boundary = 1;
        n_boundary++;
        exp = t.resp;   // either answer is legal; checked below
        if (t.resp != AXI_OKAY && t.resp != cfg.off_domain_resp)
          fail("SB_RESP", $sformatf("PD_CPU access at a power-state boundary got %s: %s",
                                    t.resp.name(), t.convert2string()));
        if (t.resp != AXI_OKAY) why = PMU_ERR_DOMAIN_OFF;
      end else if (any_off) begin
        why = PMU_ERR_DOMAIN_OFF;
        exp = cfg.off_domain_resp;
      end else begin
        exp = reg_resp(rg, t, why);
      end
    end else begin
      exp = reg_resp(rg, t, why);
    end

    b.reason   = why;
    b.exp_resp = exp;
    if (t.resp != exp)
      fail("SB_RESP", $sformatf("expected %s (%s, PD_CPU %s), got %s: %s",
                                exp.name(), why.name(), b.st.name(), t.resp.name(), t.convert2string()));

    if (rg != null && t.resp == AXI_OKAY) begin
      if (b.in_pd_cpu)              check_pd_cpu_data(rg, t);
      else if (t.kind == AXI_WRITE) update_shadow(rg, t);
      else                          check_volatile(rg, t, w);
    end
    `uvm_info("SB", $sformatf("%s -> %s [%s]", t.convert2string(), rg == null ? "<unmapped>" : rg.get_name(),
                              why.name()), UVM_HIGH)
    bus_ap.write(b);
  endfunction

  // PD_CPU register data. An OKAY access was executed while PD_CPU was
  // running, i.e. before any domain reset that happened after its request.
  protected function void check_pd_cpu_data(uvm_reg rg, axi_lite_item t);
    bit before_reset = (last_dom_reset_t >= t.t_req);
    if (t.kind == AXI_WRITE) begin
      bit [31:0] v = win_val.exists(rg) ? win_val[rg] : 32'(rg.get_reset());
      if (before_reset) return;   // overwritten by the domain reset since
      for (int i = 0; i < 4; i++) if (t.strb[i]) v[8*i +: 8] = t.data[8*i +: 8];
      win_val[rg] = v;
    end else begin
      bit [31:0] e;
      if (before_reset) e = win_before_reset.exists(rg) ? win_before_reset[rg] : 32'(rg.get_reset());
      else              e = win_val.exists(rg)          ? win_val[rg]          : 32'(rg.get_reset());
      if (t.data != e)
        fail("SB_DATA", $sformatf("%s read 0x%08h, expected 0x%08h%s", rg.get_name(), t.data, e,
                                  before_reset ? " (value before PD_CPU reset)" : ""));
    end
  endfunction

  // Read-data checks for registers the RAL treats as volatile
  virtual function void check_volatile(uvm_reg rg, axi_lite_item t, hist_t w[$]);
    if (rg == ral.STATUS && cfg.check_status_reg) begin
      bit match = 0;
      n_status_checks++;
      foreach (w[i]) if (status_matches(t.data, w[i])) match = 1;
      if (!match)
        fail("SB_STATUS", $sformatf("STATUS=0x%08h does not match any model state/pins during the read (state %s, pins %s)",
                                    t.data, w[0].st.name(), w[0].o.convert2string()));
    end else if (rg == ral.WAKE_CAUSE) begin
      bit [7:0] v = t.data[7:0];
      bit recent = (last_wake_t >= t.t_req);   // wake raced with the read
      if (!recent && (v & ~cause_possible) != 0)
        fail("SB_WAKE_CAUSE", $sformatf("WAKE_CAUSE=0x%02h has bits outside the enabled wake sources seen (0x%02h)",
                                        v, cause_possible));
    end else if (rg == ral.PD_COUNT) begin
      int unsigned lo = 0, hi = 0;
      foreach (pd_done_t[i]) begin
        if (pd_done_t[i] <= t.t_req) lo++;
        if (pd_done_t[i] <  t.t_resp) hi++;
      end
      if (t.data[15:0] < lo[15:0] || t.data[15:0] > hi[15:0])
        fail("SB_PD_COUNT", $sformatf("PD_COUNT=%0d, model counted %0d..%0d power-downs", t.data[15:0], lo, hi));
    end
  endfunction

  protected function bit status_matches(bit [31:0] v, hist_t h);
    pmu_status_state_e s;
    case (h.st)
      PMU_RUN:   s = PMU_ST_RUN;
      PMU_IDLE:  s = PMU_ST_IDLE;
      PMU_PD:    s = PMU_ST_PD;
      PMU_SLEEP: s = PMU_ST_SLEEP;
      PMU_DEEP:  s = PMU_ST_DEEP;
      default:   s = PMU_ST_PU;
    endcase
    return (v[2:0]   == s)            &&
           (v[4]     == h.o.clk_en)    &&
           (v[5]     == h.o.iso_en)    &&
           (v[6]     == h.o.ret_en)    &&
           (v[7]     == h.o.pwr_en)    &&
           (v[8]     == h.o.pwr_good)  &&
           (v[9]     == h.o.dom_rst_n) &&
           (v[13:12] == h.o.dvfs_sel);
  endfunction

  // =========================================================================
  function void check_phase(uvm_phase phase);
    if (st inside {PMU_PD, PMU_PU})
      fail("SB_END", $sformatf("test ended in the middle of a power sequence (%s), pending steps: %0d",
                               st.name(), exp_q.size()));
    if (n_snapshots == 0) fail("SB_END", "no power-interface activity observed");
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf({"\n  power snapshots   : %0d\n  sequencing steps  : %0d\n",
                               "  stable transitions: %0d\n  DVFS changes      : %0d\n",
                               "  clamp checks      : %0d\n  bus transactions  : %0d (%0d error responses, %0d at a boundary)\n",
                               "  STATUS checks     : %0d\n  scoreboard errors : %0d"},
                              n_snapshots, n_seq_steps, n_transitions, n_dvfs, n_clamp_checks,
                              n_bus, n_bus_err_resp, n_boundary, n_status_checks, n_fail), UVM_LOW)
  endfunction

endclass
