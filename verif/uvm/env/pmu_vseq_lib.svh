// pmu_vseq_lib.svh - PMU virtual sequence library
//
// Power-state transitions (one sequence per transition, plus DVFS):
//   pmu_pwr_trans_vseq     generic: RUN -> {IDLE|SLEEP|DEEP_SLEEP} -> RUN
//   pmu_idle_vseq          RUN -> IDLE -> RUN
//   pmu_sleep_vseq         RUN -> SLEEP -> RUN
//   pmu_deep_sleep_vseq    RUN -> DEEP_SLEEP -> RUN
//   pmu_wake_during_pd_vseq  wake request while the power-down sequence runs
//   pmu_dvfs_vseq          OPP change in IDLE (any OPP -> any other OPP)
//   pmu_pwr_matrix_vseq    every transition and every OPP pair, deterministic
//   pmu_pwr_rand_vseq      N random transitions / DVFS changes
// Bus traffic and registers:
//   pmu_bus_traffic_vseq   background reads/writes incl. PD_CPU registers
//   pmu_reg_rand_vseq      random register accesses through the RAL and raw AXI
//   pmu_ral_builtin_vseq   uvm_reg_hw_reset_seq + uvm_reg_bit_bash_seq
//   pmu_err_vseq           DECERR / SLVERR (reserved value, PD_CPU off) injection

typedef enum { PMU_TGT_IDLE, PMU_TGT_SLEEP, PMU_TGT_DEEP } pmu_lp_target_e;

// =============================================================================
class pmu_base_vseq extends uvm_sequence;
  `uvm_object_utils(pmu_base_vseq)
  `uvm_declare_p_sequencer(pmu_virtual_sequencer)

  pmu_reg_block     ral;
  pmu_env_cfg       cfg;
  pmu_state_tracker trk;

  function new(string name = "pmu_base_vseq");
    super.new(name);
  endfunction

  function void init();
    ral = p_sequencer.ral;
    cfg = p_sequencer.cfg;
    trk = p_sequencer.tracker;
  endfunction

  task cycles(int unsigned n);
    repeat (n) @(posedge trk.vif.clk);
  endtask

  task wait_state(pmu_state_e s, string ctx = "");
    bit ok;
    trk.wait_for(s, cfg.state_timeout, ok);
    if (!ok) `uvm_error("VSEQ", $sformatf("%s: timeout waiting for %s (model is in %s)", ctx, s.name(), trk.cur.name()))
  endtask

  task reg_write(uvm_reg rg, uvm_reg_data_t v, bit expect_ok = 1);
    uvm_status_e st;
    rg.write(st, v, .parent(this));
    if (expect_ok && st != UVM_IS_OK)
      `uvm_error("VSEQ", $sformatf("write %s=0x%0h failed", rg.get_name(), v))
    if (!expect_ok && st == UVM_IS_OK)
      `uvm_error("VSEQ", $sformatf("write %s=0x%0h unexpectedly succeeded", rg.get_name(), v))
  endtask

  task reg_read(uvm_reg rg, output uvm_reg_data_t v, input bit expect_ok = 1);
    uvm_status_e st;
    rg.read(st, v, .parent(this));
    if (expect_ok && st != UVM_IS_OK)
      `uvm_error("VSEQ", $sformatf("read %s failed", rg.get_name()))
  endtask

  task cpu_wfi();
    pwr_wfi_seq s = pwr_wfi_seq::type_id::create("wfi");
    if (!s.randomize()) `uvm_fatal("VSEQ", "randomize failed")
    s.start(p_sequencer.pwr_sqr, this);
  endtask

  task wake(bit [`PWR_IRQ_W-1:0] irq);
    pwr_wake_seq s = pwr_wake_seq::type_id::create("wake");
    if (!s.randomize() with { irq == local::irq; }) `uvm_fatal("VSEQ", "randomize failed")
    s.start(p_sequencer.pwr_sqr, this);
  endtask

  task irq_pulse(bit [`PWR_IRQ_W-1:0] irq);
    pwr_irq_pulse_seq s = pwr_irq_pulse_seq::type_id::create("pulse");
    if (!s.randomize() with { irq == local::irq; }) `uvm_fatal("VSEQ", "randomize failed")
    s.start(p_sequencer.pwr_sqr, this);
  endtask

  // Raw AXI access (bypasses the RAL; prediction still happens via the monitor)
  task axi_write(bit [31:0] addr, bit [31:0] data, output axi_lite_resp_e r,
                 input bit [3:0] strb = 4'hF, input axi_lite_dly_e dly = AXI_DLY_RANDOM);
    axi_lite_base_seq s = axi_lite_base_seq::type_id::create("aw");
    s.dly_mode = dly;
    s.set_sequencer(p_sequencer.axi_sqr);
    s.set_parent_sequence(this);
    s.write(addr, data, r, strb);
  endtask

  task axi_read(bit [31:0] addr, output bit [31:0] data, output axi_lite_resp_e r,
                input axi_lite_dly_e dly = AXI_DLY_RANDOM);
    axi_lite_base_seq s = axi_lite_base_seq::type_id::create("ar");
    s.dly_mode = dly;
    s.set_sequencer(p_sequencer.axi_sqr);
    s.set_parent_sequence(this);
    s.read(addr, data, r);
  endtask

  function bit [31:0] reg_addr(uvm_reg rg);
    return rg.get_address(ral.default_map);
  endfunction

endclass

// =============================================================================
// Generic low-power round trip: RUN -> target -> RUN
class pmu_pwr_trans_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_pwr_trans_vseq)

  rand pmu_lp_target_e         target;
  rand bit                     change_dvfs;   // program a new OPP before WFI
  rand bit [1:0]               opp;
  rand int unsigned            dwell;         // cycles spent in the low-power state
  rand bit                     wake_early;    // wake while power-down is in progress
  rand bit [`PWR_IRQ_W-1:0]    mask;
  rand bit [`PWR_IRQ_W-1:0]    wake_irq;
  rand bit                     masked_noise;  // pulse disabled wake sources first
  rand bit                     idle_ret;      // IDLE with RET_EN=1 (must still be IDLE)
  rand bit                     set_delay;
  rand bit [7:0]               seq_delay;

  constraint c_opp    { opp < PMU_N_OPP; }
  constraint c_mask   { mask != 0; (wake_irq & mask) != 0; $countones(wake_irq) <= 3;
                        mask dist { 8'hFF := 3, [8'h01:8'hFE] :/ 7 }; }
  constraint c_early  { (target == PMU_TGT_IDLE) -> !wake_early; wake_early dist { 0 := 4, 1 := 1 }; }
  constraint c_dwell  { dwell dist { [0:10] := 3, [11:100] := 4, [101:400] := 2 }; }
  constraint c_ret    { (target != PMU_TGT_IDLE) -> !idle_ret; }
  constraint c_delay  { seq_delay inside {[1:8]}; set_delay dist { 0 := 3, 1 := 1 }; }
  constraint c_dvfs   { change_dvfs dist { 0 := 2, 1 := 1 }; }

  function new(string name = "pmu_pwr_trans_vseq");
    super.new(name);
  endfunction

  function pmu_state_e target_state();
    case (target)
      PMU_TGT_IDLE:  return PMU_IDLE;
      PMU_TGT_SLEEP: return PMU_SLEEP;
      default:       return PMU_DEEP;
    endcase
  endfunction

  task body();
    bit [1:0] ctrl;
    init();
    wait_state(PMU_RUN, get_name());
    `uvm_info("VSEQ", $sformatf("RUN -> %s -> RUN (dvfs=%0b opp=%0d dwell=%0d early_wake=%0b mask=0x%02h irq=0x%02h)",
                                target_state().name(), change_dvfs, opp, dwell, wake_early, mask, wake_irq), UVM_MEDIUM)
    if (set_delay)   reg_write(ral.SEQ_DELAY, seq_delay);
    reg_write(ral.WAKE_MASK, mask);
    if (change_dvfs) reg_write(ral.DVFS, opp);
    case (target)
      PMU_TGT_IDLE:  ctrl = idle_ret ? 2'b10 : 2'b00;   // {RET_EN, PD_EN}
      PMU_TGT_SLEEP: ctrl = 2'b01;
      default:       ctrl = 2'b11;
    endcase
    reg_write(ral.CTRL, ctrl);

    cpu_wfi();
    if (wake_early) begin
      wait_state(PMU_PD, get_name());
      wake(wake_irq);
      wait_state(target_state(), get_name());
    end else begin
      wait_state(target_state(), get_name());
      if (masked_noise && (~mask != 0)) irq_pulse(~mask & 8'($urandom | 1 << $urandom_range(7)));
      cycles(dwell);
      wake(wake_irq);
    end
    wait_state(PMU_RUN, get_name());
  endtask
endclass

class pmu_idle_vseq extends pmu_pwr_trans_vseq;
  `uvm_object_utils(pmu_idle_vseq)
  constraint c_tgt { target == PMU_TGT_IDLE; }
  function new(string name = "pmu_idle_vseq"); super.new(name); endfunction
endclass

class pmu_sleep_vseq extends pmu_pwr_trans_vseq;
  `uvm_object_utils(pmu_sleep_vseq)
  constraint c_tgt { target == PMU_TGT_SLEEP; }
  function new(string name = "pmu_sleep_vseq"); super.new(name); endfunction
endclass

class pmu_deep_sleep_vseq extends pmu_pwr_trans_vseq;
  `uvm_object_utils(pmu_deep_sleep_vseq)
  constraint c_tgt { target == PMU_TGT_DEEP; }
  function new(string name = "pmu_deep_sleep_vseq"); super.new(name); endfunction
endclass

class pmu_wake_during_pd_vseq extends pmu_pwr_trans_vseq;
  `uvm_object_utils(pmu_wake_during_pd_vseq)
  constraint c_tgt { target != PMU_TGT_IDLE; wake_early == 1; }
  function new(string name = "pmu_wake_during_pd_vseq"); super.new(name); endfunction
endclass

// DVFS: move to a different OPP through IDLE
class pmu_dvfs_vseq extends pmu_pwr_trans_vseq;
  `uvm_object_utils(pmu_dvfs_vseq)
  int to_opp = -1;   // >= 0: force this OPP
  constraint c_tgt { target == PMU_TGT_IDLE; change_dvfs == 1; }
  function new(string name = "pmu_dvfs_vseq"); super.new(name); endfunction
  task body();
    init();
    if (to_opp >= 0) opp = to_opp[1:0];
    else if (opp == trk.opp) opp = (trk.opp + 1) % PMU_N_OPP;
    super.body();
    if (trk.opp != opp)
      `uvm_error("VSEQ", $sformatf("DVFS: still at OPP%0d after IDLE, programmed OPP%0d", trk.opp, opp))
  endtask
endclass

// =============================================================================
// Deterministic walk of the full transition matrix and all OPP pairs
class pmu_pwr_matrix_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_pwr_matrix_vseq)
  function new(string name = "pmu_pwr_matrix_vseq"); super.new(name); endfunction

  task body();
    int unsigned dwells[3] = '{2, 50, 300};
    int          opps[6]   = '{1, 2, 0, 2, 1, 0};   // 0->1->2->0->2->1->0
    init();
    // Every low-power state, three dwell lengths, normal and early wake
    foreach (dwells[d]) begin
      for (int t = 0; t < 3; t++) begin
        pmu_pwr_trans_vseq s = pmu_pwr_trans_vseq::type_id::create($sformatf("m_%0d_%0d", t, d));
        if (!s.randomize() with { target == pmu_lp_target_e'(t); dwell == dwells[d];
                                  wake_early == 0; change_dvfs == 0; })
          `uvm_fatal("VSEQ", "randomize failed")
        s.start(p_sequencer, this);
      end
    end
    for (int t = 1; t < 3; t++) begin
      pmu_pwr_trans_vseq s = pmu_pwr_trans_vseq::type_id::create($sformatf("early_%0d", t));
      if (!s.randomize() with { target == pmu_lp_target_e'(t); wake_early == 1; change_dvfs == 0; })
        `uvm_fatal("VSEQ", "randomize failed")
      s.start(p_sequencer, this);
    end
    // IDLE entered with RET_EN=1 but PD_EN=0 must remain IDLE
    begin
      pmu_idle_vseq s = pmu_idle_vseq::type_id::create("idle_ret");
      if (!s.randomize() with { idle_ret == 1; change_dvfs == 0; }) `uvm_fatal("VSEQ", "randomize failed")
      s.start(p_sequencer, this);
    end
    // Every OPP -> OPP change
    foreach (opps[i]) begin
      pmu_dvfs_vseq s = pmu_dvfs_vseq::type_id::create($sformatf("dvfs_%0d", i));
      if (!s.randomize() with { wake_early == 0; }) `uvm_fatal("VSEQ", "randomize failed")
      s.to_opp = opps[i];
      s.start(p_sequencer, this);
    end
    // A DVFS target written before SLEEP stays pending until the next IDLE
    begin
      pmu_sleep_vseq s = pmu_sleep_vseq::type_id::create("dvfs_before_sleep");
      if (!s.randomize() with { change_dvfs == 1; opp == 1; }) `uvm_fatal("VSEQ", "randomize failed")
      s.start(p_sequencer, this);
    end
    begin
      pmu_dvfs_vseq s = pmu_dvfs_vseq::type_id::create("dvfs_after_sleep");
      if (!s.randomize()) `uvm_fatal("VSEQ", "randomize failed")
      s.to_opp = 0;
      s.start(p_sequencer, this);
    end
  endtask
endclass

// =============================================================================
class pmu_pwr_rand_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_pwr_rand_vseq)
  rand int unsigned n;
  constraint c_n { n inside {[10:30]}; }
  function new(string name = "pmu_pwr_rand_vseq"); super.new(name); endfunction
  task body();
    init();
    for (int i = 0; i < n; i++) begin
      pmu_pwr_trans_vseq s;
      if ($urandom_range(4) == 0) begin
        pmu_dvfs_vseq d = pmu_dvfs_vseq::type_id::create($sformatf("rnd_dvfs_%0d", i));
        s = d;
      end else begin
        s = pmu_pwr_trans_vseq::type_id::create($sformatf("rnd_%0d", i));
      end
      if (!s.randomize()) `uvm_fatal("VSEQ", "randomize failed")
      s.start(p_sequencer, this);
    end
  endtask
endclass

// =============================================================================
// Background bus traffic, safe to run during power transitions: reads of every
// register, writes only to PD_CPU registers and WAKE_CAUSE (W1C), occasional
// unmapped accesses. Runs until `stop` is set.
class pmu_bus_traffic_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_bus_traffic_vseq)
  bit          stop;
  int unsigned n_done;
  function new(string name = "pmu_bus_traffic_vseq"); super.new(name); endfunction

  task body();
    uvm_reg regs[$], win[$];
    init();
    ral.get_registers(regs);
    ral.CPU_WIN.get_registers(win);
    while (!stop) begin
      axi_lite_resp_e r;
      bit [31:0]      d;
      axi_lite_dly_e  dly = axi_lite_dly_e'($urandom_range(2));
      int unsigned    k   = $urandom_range(99);
      if (k < 45) begin
        axi_read(reg_addr(regs[$urandom_range(regs.size() - 1)]), d, r, dly);
      end else if (k < 85) begin
        axi_write(reg_addr(win[$urandom_range(win.size() - 1)]), $urandom, r,
                  ($urandom_range(3) == 0) ? 4'($urandom) : 4'hF, dly);
      end else if (k < 92) begin
        axi_write(reg_addr(ral.WAKE_CAUSE), $urandom, r, 4'hF, dly);
      end else begin
        bit [31:0] a = cfg.base_addr + 32'h20 + 4 * $urandom_range(30);   // 0x20..0x98 unmapped
        if ($urandom_range(1)) axi_read(a, d, r, dly); else axi_write(a, $urandom, r, 4'hF, dly);
      end
      n_done++;
      cycles($urandom_range(6));
    end
  endtask
endclass

// =============================================================================
// Random register accesses (domain kept in RUN)
class pmu_reg_rand_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_reg_rand_vseq)
  rand int unsigned n;
  constraint c_n { n inside {[100:300]}; }
  function new(string name = "pmu_reg_rand_vseq"); super.new(name); endfunction

  task body();
    uvm_reg rw_regs[$], all[$];
    init();
    wait_state(PMU_RUN, get_name());
    ral.get_registers(all);
    rw_regs = '{ral.CTRL, ral.DVFS, ral.WAKE_MASK, ral.SEQ_DELAY,
                ral.CPU_WIN.SCRATCH[0], ral.CPU_WIN.SCRATCH[1], ral.CPU_WIN.SCRATCH[2], ral.CPU_WIN.SCRATCH[3]};
    for (int i = 0; i < n; i++) begin
      uvm_reg         rg = rw_regs[$urandom_range(rw_regs.size() - 1)];
      uvm_reg_data_t  v;
      uvm_status_e    st;
      axi_lite_resp_e r;
      bit [31:0]      d;
      case ($urandom_range(5))
        0, 1: begin   // RAL write of a constrained-random value, then read back
          // Retry until the register's own constraints hold. Verilator 5.054
          // was observed to ignore pmu_reg_dvfs::c_legal when the RAL field
          // covergroups are built; on a compliant simulator this loop exits
          // after the first randomize().
          repeat (16) begin
            if (!rg.randomize()) `uvm_fatal("VSEQ", "reg randomize failed")
            if (rg != ral.DVFS || ral.DVFS.OPP.get() < PMU_N_OPP) break;
          end
          if (rg == ral.DVFS && ral.DVFS.OPP.get() >= PMU_N_OPP) void'(ral.DVFS.OPP.randomize() with { value < PMU_N_OPP; });
          reg_write(rg, rg.get());
          reg_read(rg, v);
        end
        2: begin      // RAL mirror with check (PD_AON registers)
          uvm_reg any = all[$urandom_range(all.size() - 1)];
          if (!ral.in_pd_cpu(any)) any.mirror(st, UVM_CHECK, .parent(this));
          else                     reg_read(any, v);
        end
        3: begin      // raw write with random data and byte strobes (reserved values included)
          axi_write(reg_addr(rg), $urandom, r, 4'($urandom), axi_lite_dly_e'($urandom_range(3)));
          axi_read(reg_addr(rg), d, r);
        end
        4: begin      // back-to-back burst over all registers
          axi_lite_b2b_seq b = axi_lite_b2b_seq::type_id::create("b2b");
          foreach (all[j]) if (all[j] != ral.CTRL && all[j] != ral.DVFS) b.addrs.push_back(reg_addr(all[j]));
          if (!b.randomize() with { mode inside {axi_lite_b2b_seq::B2B_READS, axi_lite_b2b_seq::B2B_ALTERNATE,
                                                 axi_lite_b2b_seq::B2B_WR_THEN_RD}; })
            `uvm_fatal("VSEQ", "randomize failed")
          b.start(p_sequencer.axi_sqr, this);
        end
        default: begin // read every register
          foreach (all[j]) begin
            axi_read(reg_addr(all[j]), d, r, AXI_DLY_ZERO);
          end
        end
      endcase
    end
    // Leave the DUT in a known state for anything that follows
    reg_write(ral.CTRL, 0);
    reg_write(ral.WAKE_MASK, 8'hFF);
    reg_write(ral.SEQ_DELAY, 4);
  endtask
endclass

// =============================================================================
class pmu_ral_builtin_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_ral_builtin_vseq)
  bit do_hw_reset = 1;
  bit do_bit_bash = 1;
  function new(string name = "pmu_ral_builtin_vseq"); super.new(name); endfunction
  task body();
    init();
    wait_state(PMU_RUN, get_name());
    if (do_hw_reset) begin
      uvm_reg_hw_reset_seq s = uvm_reg_hw_reset_seq::type_id::create("hw_reset");
      s.model = ral;
      `uvm_info("VSEQ", "running uvm_reg_hw_reset_seq", UVM_LOW)
      s.start(null, this);
    end
    if (do_bit_bash) begin
      uvm_reg_bit_bash_seq s = uvm_reg_bit_bash_seq::type_id::create("bit_bash");
      s.model = ral;
      `uvm_info("VSEQ", "running uvm_reg_bit_bash_seq", UVM_LOW)
      s.start(null, this);
    end
  endtask
endclass

// =============================================================================
// Error injection: every way to get an error response from the PMU
class pmu_err_vseq extends pmu_base_vseq;
  `uvm_object_utils(pmu_err_vseq)
  int unsigned n_okay, n_slverr, n_decerr;
  function new(string name = "pmu_err_vseq"); super.new(name); endfunction

  protected function void count(axi_lite_resp_e r);
    case (r)
      AXI_OKAY:   n_okay++;
      AXI_SLVERR: n_slverr++;
      AXI_DECERR: n_decerr++;
      default: ;
    endcase
  endfunction

  // Hammer the PD_CPU registers with reads and writes
  task hammer_win(int unsigned n);
    uvm_reg win[$];
    axi_lite_resp_e r;
    bit [31:0] d;
    ral.CPU_WIN.get_registers(win);
    repeat (n) begin
      bit [31:0] a = reg_addr(win[$urandom_range(win.size() - 1)]);
      if ($urandom_range(1)) axi_write(a, $urandom, r, 4'hF, AXI_DLY_ZERO);
      else                   axi_read(a, d, r, AXI_DLY_ZERO);
      count(r);
    end
  endtask

  task body();
    axi_lite_err_seq unm;
    axi_lite_resp_e  r;
    bit [31:0]       d;
    init();
    wait_state(PMU_RUN, get_name());

    // 1. Unmapped addresses -> DECERR
    unm = axi_lite_err_seq::type_id::create("unmapped");
    unm.addrs = '{cfg.base_addr + 32'h020, cfg.base_addr + 32'h0FC, cfg.base_addr + 32'h110,
                  cfg.base_addr + 32'h200, cfg.base_addr + 32'hFFC, cfg.base_addr + 32'h1000,
                  32'h8000_0000, 32'hFFFF_FFFC};
    unm.reps = 3;
    unm.dly_mode = AXI_DLY_RANDOM;
    unm.start(p_sequencer.axi_sqr, this);
    n_okay += unm.n_okay; n_slverr += unm.n_slverr; n_decerr += unm.n_decerr;

    // 2. Reserved DVFS operating point -> SLVERR, register unchanged
    axi_write(reg_addr(ral.DVFS), 32'h3, r);                  count(r);
    axi_write(reg_addr(ral.DVFS), 32'hFFFF_FFFF, r);          count(r);
    axi_write(reg_addr(ral.DVFS), 32'h3, r, 4'b1110);         count(r);   // lane 0 not written: OKAY
    reg_write(ral.DVFS, 3, .expect_ok(0));
    axi_read(reg_addr(ral.DVFS), d, r);                       count(r);   // predictor checks unchanged

    // 3. PD_CPU registers while PD_CPU is not running -> SLVERR
    hammer_win(4);                                            // RUN: OKAY
    for (int t = 0; t < 3; t++) begin
      pmu_pwr_trans_vseq      s = pmu_pwr_trans_vseq::type_id::create($sformatf("err_lp_%0d", t));
      pmu_bus_traffic_vseq    bg = pmu_bus_traffic_vseq::type_id::create("bg");
      if (!s.randomize() with { target == pmu_lp_target_e'(t); dwell inside {[150:300]};
                                wake_early == 0; change_dvfs == 0; })
        `uvm_fatal("VSEQ", "randomize failed")
      fork
        s.start(p_sequencer, this);
        begin
          wait_state(s.target_state(), "err");
          hammer_win(10);
        end
        begin
          // traffic across the PD / PU boundaries as well
          bit ok;
          fork bg.start(p_sequencer, this); join_none
          trk.wait_leave(PMU_RUN, cfg.state_timeout, ok);
          trk.wait_for(PMU_RUN, cfg.state_timeout, ok);
          bg.stop = 1;
        end
      join
      wait fork;
      hammer_win(4);                                          // back in RUN: OKAY, reset values
    end

    `uvm_info("VSEQ", $sformatf("error injection responses: OKAY=%0d SLVERR=%0d DECERR=%0d",
                                n_okay, n_slverr, n_decerr), UVM_LOW)
    if (n_decerr == 0) `uvm_error("VSEQ", "no DECERR was provoked")
    if (n_slverr == 0) `uvm_error("VSEQ", "no SLVERR was provoked")
  endtask
endclass
