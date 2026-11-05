// -----------------------------------------------------------------------------
// pmu_test_pkg.sv - PMU UVM tests
//
//   pmu_smoke_test        cold boot, ID/scratch access, one IDLE and one SLEEP
//   pmu_ral_test          uvm_reg_hw_reset_seq + uvm_reg_bit_bash_seq
//   pmu_rand_reg_test     random register traffic (RAL + raw AXI, strobes, b2b)
//   pmu_rand_pwr_test     random power transitions + DVFS mixed with bus traffic
//   pmu_pwr_matrix_test   deterministic full transition matrix + all OPP pairs
//   pmu_err_test          DECERR / SLVERR injection, PD_CPU accessed while off
//   pmu_full_test         everything above in one run (coverage closure)
//
// Plusargs:  +UVM_TESTNAME=<test>  +PMU_ITERS=<n>  +PMU_BASE=<hex>
// Seed:      simulator option (see scripts/), e.g. xrun -svseed, vsim -sv_seed,
//            vcs +ntb_random_seed, verilator +verilator+seed+
// -----------------------------------------------------------------------------
`include "pwr_defines.svh"
package pmu_test_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;
  import pwr_pkg::*;
  import pmu_ral_pkg::*;
  import pmu_env_pkg::*;

  class pmu_base_test extends uvm_test;
    `uvm_component_utils(pmu_base_test)

    pmu_env     env;
    pmu_env_cfg cfg;
    int unsigned iters = 0;     // 0: test default

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      string s;
      super.build_phase(phase);
      cfg = pmu_env_cfg::type_id::create("cfg");
      if (!uvm_config_db#(virtual axi_lite_if)::get(this, "", "axi_vif", cfg.axi_cfg.vif))
        `uvm_fatal("CFG", "axi_vif not in config_db")
      if (!uvm_config_db#(virtual pwr_if)::get(this, "", "pwr_vif", cfg.pwr_cfg_h.vif))
        `uvm_fatal("CFG", "pwr_vif not in config_db")
      void'(uvm_config_db#(bit [`PWR_ISO_W-1:0])::get(this, "", "iso_clamp", cfg.iso_clamp));
      if ($value$plusargs("PMU_BASE=%h", cfg.base_addr)) ;
      if ($value$plusargs("PMU_ITERS=%d", iters)) ;
      configure(cfg);
      uvm_config_db#(pmu_env_cfg)::set(this, "env", "cfg", cfg);
      env = pmu_env::type_id::create("env", this);
    endfunction

    // Hook for derived tests
    virtual function void configure(pmu_env_cfg c);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      if (uvm_report_enabled(UVM_HIGH)) uvm_top.print_topology();
    endfunction

    task run_phase(uvm_phase phase);
      bit ok;
      phase.raise_objection(this);
      phase.phase_done.set_drain_time(this, 200ns);
      // cold boot: PMU must bring PD_CPU up after PD_AON reset
      env.tracker.wait_for(PMU_RUN, 5000, ok);
      if (!ok) `uvm_fatal("TEST", "PD_CPU did not reach RUN after reset (cold boot)")
      main();
      phase.drop_objection(this);
    endtask

    virtual task main();
    endtask

    // Start a virtual sequence on the environment's virtual sequencer
    task run_vseq(pmu_base_vseq s);
      s.start(env.vsqr);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int n_err = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
      if (n_err == 0)
        `uvm_info("TEST", $sformatf("*** TEST PASSED *** %s", get_type_name()), UVM_NONE)
      else
        `uvm_info("TEST", $sformatf("*** TEST FAILED *** %s (%0d errors)", get_type_name(), n_err), UVM_NONE)
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_smoke_test extends pmu_base_test;
    `uvm_component_utils(pmu_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task main();
      pmu_base_vseq   b = pmu_base_vseq::type_id::create("b");
      pmu_idle_vseq   i = pmu_idle_vseq::type_id::create("idle");
      pmu_sleep_vseq  s = pmu_sleep_vseq::type_id::create("sleep");
      uvm_reg_data_t  v;
      uvm_status_e    st;
      b.set_sequencer(env.vsqr);
      b.init();
      env.ral.ID.mirror(st, UVM_CHECK);
      if (st != UVM_IS_OK) `uvm_error("TEST", "ID read failed")
      b.reg_write(env.ral.CPU_WIN.SCRATCH[0], 32'hCAFE_F00D);
      b.reg_read(env.ral.CPU_WIN.SCRATCH[0], v);
      if (v != 32'hCAFE_F00D) `uvm_error("TEST", $sformatf("SCRATCH0 read 0x%08h", v))
      if (!i.randomize() with { change_dvfs == 0; }) `uvm_fatal("TEST", "randomize failed")
      run_vseq(i);
      if (!s.randomize() with { wake_early == 0; dwell < 50; }) `uvm_fatal("TEST", "randomize failed")
      run_vseq(s);
      // PD_CPU registers are not retained across SLEEP (scoreboard checks 0)
      b.reg_read(env.ral.CPU_WIN.SCRATCH[0], v);
      env.ral.STATUS.mirror(st, UVM_NO_CHECK);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_ral_test extends pmu_base_test;
    `uvm_component_utils(pmu_ral_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_ral_builtin_vseq s = pmu_ral_builtin_vseq::type_id::create("ral");
      string which;
      if ($value$plusargs("RAL_SEQ=%s", which)) begin
        s.do_hw_reset = (which == "hw_reset" || which == "all");
        s.do_bit_bash = (which == "bit_bash" || which == "all");
      end
      run_vseq(s);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_rand_reg_test extends pmu_base_test;
    `uvm_component_utils(pmu_rand_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_reg_rand_vseq s = pmu_reg_rand_vseq::type_id::create("reg_rand");
      if (!s.randomize() with { (iters != 0) -> n == iters; }) `uvm_fatal("TEST", "randomize failed")
      run_vseq(s);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_rand_pwr_test extends pmu_base_test;
    `uvm_component_utils(pmu_rand_pwr_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_pwr_rand_vseq    p  = pmu_pwr_rand_vseq::type_id::create("pwr_rand");
      pmu_bus_traffic_vseq bg = pmu_bus_traffic_vseq::type_id::create("traffic");
      if (!p.randomize() with { (iters != 0) -> n == iters; }) `uvm_fatal("TEST", "randomize failed")
      fork
        bg.start(env.vsqr);
        begin
          run_vseq(p);
          bg.stop = 1;
        end
      join
      `uvm_info("TEST", $sformatf("%0d background bus transactions", bg.n_done), UVM_LOW)
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_pwr_matrix_test extends pmu_base_test;
    `uvm_component_utils(pmu_pwr_matrix_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_pwr_matrix_vseq s = pmu_pwr_matrix_vseq::type_id::create("matrix");
      run_vseq(s);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_err_test extends pmu_base_test;
    `uvm_component_utils(pmu_err_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_err_vseq s = pmu_err_vseq::type_id::create("err");
      run_vseq(s);
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class pmu_full_test extends pmu_base_test;
    `uvm_component_utils(pmu_full_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task main();
      pmu_ral_builtin_vseq ral_s = pmu_ral_builtin_vseq::type_id::create("ral");
      pmu_reg_rand_vseq    reg_s = pmu_reg_rand_vseq::type_id::create("reg_rand");
      pmu_pwr_matrix_vseq  mat_s = pmu_pwr_matrix_vseq::type_id::create("matrix");
      pmu_pwr_rand_vseq    pwr_s = pmu_pwr_rand_vseq::type_id::create("pwr_rand");
      pmu_bus_traffic_vseq bg    = pmu_bus_traffic_vseq::type_id::create("traffic");
      pmu_err_vseq         err_s = pmu_err_vseq::type_id::create("err");
      run_vseq(ral_s);
      if (!reg_s.randomize() with { n == 100; }) `uvm_fatal("TEST", "randomize failed")
      run_vseq(reg_s);
      fork
        bg.start(env.vsqr);
        begin
          run_vseq(mat_s);
          if (!pwr_s.randomize()) `uvm_fatal("TEST", "randomize failed")
          run_vseq(pwr_s);
          bg.stop = 1;
        end
      join
      run_vseq(err_s);
    endtask
  endclass

endpackage
