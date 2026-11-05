// -----------------------------------------------------------------------------
// pmu_ral_pkg.sv - UVM register model of the PMU
//
// This is the only file that encodes the PMU register map. It matches the stub
// in verif/uvm/stub/pmu_stub.sv (SPEC.md does not define a map). When the real
// PMU is swapped in, regenerate/edit this file; the agents, scoreboard and
// tests reach registers only through this model.
//
//   0x000 ID          RO   PMU identification
//   0x004 CTRL        RW   [0] PD_EN  : WFI powers PD_CPU off (else IDLE)
//                          [1] RET_EN : power-off uses RAM retention (DEEP_SLEEP)
//   0x008 STATUS      RO   [2:0] STATE  [4] CLK_EN [5] ISO_EN [6] RET_EN
//                          [7] PWR_EN [8] PWR_GOOD [9] CPU_RST_N
//                          [13:12] DVFS_CUR [16] DVFS_PEND   (all volatile)
//   0x00C DVFS        RW   [1:0] OPP target (3 = reserved -> SLVERR)
//   0x010 WAKE_MASK   RW   [7:0] wake source enables
//   0x014 WAKE_CAUSE  W1C  [7:0] wake sources that caused the last wake-ups
//   0x018 SEQ_DELAY   RW   [7:0] cycles between sequencing steps
//   0x01C PD_COUNT    RO   [15:0] completed power-down count (volatile)
//   0x100 CPU_WIN.SCRATCH[0..3]  RW, physically in PD_CPU:
//                          SLVERR unless PD_CPU is RUNning, reset on power-off
// -----------------------------------------------------------------------------
package pmu_ral_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // STATUS.STATE encoding
  typedef enum bit [2:0] {
    PMU_ST_RUN   = 3'd0,
    PMU_ST_IDLE  = 3'd1,
    PMU_ST_SLEEP = 3'd2,
    PMU_ST_DEEP  = 3'd3,
    PMU_ST_PD    = 3'd4,
    PMU_ST_PU    = 3'd5
  } pmu_status_state_e;

  localparam bit [31:0] PMU_ID_VALUE = 32'h504D_5501;
  localparam int        PMU_N_OPP    = 3;

  // ---------------------------------------------------------------------------
  class pmu_reg_id extends uvm_reg;
    `uvm_object_utils(pmu_reg_id)
    rand uvm_reg_field ID;
    function new(string name = "pmu_reg_id");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    virtual function void build();
      ID = uvm_reg_field::type_id::create("ID");
      ID.configure(this, 32, 0, "RO", 0, PMU_ID_VALUE, 1, 0, 1);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_ctrl extends uvm_reg;
    `uvm_object_utils(pmu_reg_ctrl)
    rand uvm_reg_field PD_EN;
    rand uvm_reg_field RET_EN;

    covergroup cg_vals with function sample(bit pd_en, bit ret_en, bit is_read);
      option.per_instance = 1;
      cp_mode: coverpoint {pd_en, ret_en} iff (!is_read) {
        bins idle_only  = {2'b00};
        bins idle_ret   = {2'b01};   // RET_EN without PD_EN: still IDLE
        bins sleep      = {2'b10};
        bins deep_sleep = {2'b11};
      }
      cp_dir: coverpoint is_read;
    endgroup

    function new(string name = "pmu_reg_ctrl");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      PD_EN  = uvm_reg_field::type_id::create("PD_EN");
      RET_EN = uvm_reg_field::type_id::create("RET_EN");
      PD_EN.configure (this, 1, 0, "RW", 0, 1'b0, 1, 1, 0);
      RET_EN.configure(this, 1, 1, "RW", 0, 1'b0, 1, 1, 0);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[0], data[1], is_read);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_status extends uvm_reg;
    `uvm_object_utils(pmu_reg_status)
    uvm_reg_field STATE, CLK_EN, ISO_EN, RET_EN, PWR_EN, PWR_GOOD, CPU_RST_N, DVFS_CUR, DVFS_PEND;

    covergroup cg_vals with function sample(bit [2:0] st, bit [1:0] opp);
      option.per_instance = 1;
      cp_state: coverpoint st {
        bins run = {0}; bins idle = {1}; bins sleep = {2}; bins deep = {3};
        bins pd = {4}; bins pu = {5}; illegal_bins bad = {[6:7]};
      }
      cp_opp: coverpoint opp { bins opp[] = {[0:2]}; illegal_bins bad = {3}; }
    endgroup

    function new(string name = "pmu_reg_status");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      STATE     = uvm_reg_field::type_id::create("STATE");
      CLK_EN    = uvm_reg_field::type_id::create("CLK_EN");
      ISO_EN    = uvm_reg_field::type_id::create("ISO_EN");
      RET_EN    = uvm_reg_field::type_id::create("RET_EN");
      PWR_EN    = uvm_reg_field::type_id::create("PWR_EN");
      PWR_GOOD  = uvm_reg_field::type_id::create("PWR_GOOD");
      CPU_RST_N = uvm_reg_field::type_id::create("CPU_RST_N");
      DVFS_CUR  = uvm_reg_field::type_id::create("DVFS_CUR");
      DVFS_PEND = uvm_reg_field::type_id::create("DVFS_PEND");
      //                        parent bits lsb  acc   vol reset has_rst rand indiv
      STATE.configure    (this, 3,   0,  "RO", 1,  3'd0, 0, 0, 0);
      CLK_EN.configure   (this, 1,   4,  "RO", 1,  1'b0, 0, 0, 0);
      ISO_EN.configure   (this, 1,   5,  "RO", 1,  1'b0, 0, 0, 0);
      RET_EN.configure   (this, 1,   6,  "RO", 1,  1'b0, 0, 0, 0);
      PWR_EN.configure   (this, 1,   7,  "RO", 1,  1'b0, 0, 0, 0);
      PWR_GOOD.configure (this, 1,   8,  "RO", 1,  1'b0, 0, 0, 0);
      CPU_RST_N.configure(this, 1,   9,  "RO", 1,  1'b0, 0, 0, 0);
      DVFS_CUR.configure (this, 2,  12,  "RO", 1,  2'd0, 0, 0, 0);
      DVFS_PEND.configure(this, 1,  16,  "RO", 1,  1'b0, 0, 0, 0);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (is_read && get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[2:0], data[13:12]);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_dvfs extends uvm_reg;
    `uvm_object_utils(pmu_reg_dvfs)
    rand uvm_reg_field OPP;
    constraint c_legal { OPP.value < PMU_N_OPP; }

    covergroup cg_vals with function sample(bit [1:0] opp, bit is_read);
      option.per_instance = 1;
      cp_opp_wr: coverpoint opp iff (!is_read) { bins opp[] = {[0:2]}; bins reserved = {3}; }
      cp_opp_rd: coverpoint opp iff (is_read)  { bins opp[] = {[0:2]}; illegal_bins reserved = {3}; }
    endgroup

    function new(string name = "pmu_reg_dvfs");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      OPP = uvm_reg_field::type_id::create("OPP");
      OPP.configure(this, 2, 0, "RW", 0, 2'd0, 1, 1, 1);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[1:0], is_read);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_wake_mask extends uvm_reg;
    `uvm_object_utils(pmu_reg_wake_mask)
    rand uvm_reg_field MASK;

    covergroup cg_vals with function sample(bit [7:0] m, bit is_read);
      option.per_instance = 1;
      cp_bits: coverpoint m iff (!is_read) {
        bins none   = {8'h00};
        bins all    = {8'hFF};
        bins single[] = {8'h01, 8'h02, 8'h04, 8'h08, 8'h10, 8'h20, 8'h40, 8'h80};
        bins multi  = default;
      }
    endgroup

    function new(string name = "pmu_reg_wake_mask");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      MASK = uvm_reg_field::type_id::create("MASK");
      MASK.configure(this, 8, 0, "RW", 0, 8'hFF, 1, 1, 1);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[7:0], is_read);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_wake_cause extends uvm_reg;
    `uvm_object_utils(pmu_reg_wake_cause)
    rand uvm_reg_field CAUSE;

    covergroup cg_vals with function sample(bit [7:0] c, bit is_read);
      option.per_instance = 1;
      cp_rd: coverpoint (c != 0) iff (is_read) { bins clear = {0}; bins set = {1}; }
      cp_w1c: coverpoint (c != 0) iff (!is_read) { bins w1c = {1}; bins noop = {0}; }
    endgroup

    function new(string name = "pmu_reg_wake_cause");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      CAUSE = uvm_reg_field::type_id::create("CAUSE");
      CAUSE.configure(this, 8, 0, "W1C", 1, 8'h00, 1, 0, 1);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[7:0], is_read);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_seq_delay extends uvm_reg;
    `uvm_object_utils(pmu_reg_seq_delay)
    rand uvm_reg_field DELAY;
    constraint c_sane { DELAY.value inside {[1:32]}; }

    covergroup cg_vals with function sample(bit [7:0] d, bit is_read);
      option.per_instance = 1;
      cp_delay: coverpoint d iff (!is_read) {
        bins zero = {0}; bins one = {1}; bins short_d = {[2:7]}; bins mid = {[8:31]}; bins long_d = {[32:255]};
      }
    endgroup

    function new(string name = "pmu_reg_seq_delay");
      super.new(name, 32, build_coverage(UVM_CVR_FIELD_VALS));
      if (has_coverage(UVM_CVR_FIELD_VALS)) cg_vals = new();
    endfunction
    virtual function void build();
      DELAY = uvm_reg_field::type_id::create("DELAY");
      DELAY.configure(this, 8, 0, "RW", 0, 8'd4, 1, 1, 1);
    endfunction
    virtual function void sample(uvm_reg_data_t data, uvm_reg_data_t byte_en,
                                 bit is_read, uvm_reg_map map);
      if (get_coverage(UVM_CVR_FIELD_VALS)) cg_vals.sample(data[7:0], is_read);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_pd_count extends uvm_reg;
    `uvm_object_utils(pmu_reg_pd_count)
    uvm_reg_field COUNT;
    function new(string name = "pmu_reg_pd_count");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    virtual function void build();
      COUNT = uvm_reg_field::type_id::create("COUNT");
      COUNT.configure(this, 16, 0, "RO", 1, 16'd0, 1, 0, 1);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Registers physically inside PD_CPU (power-gated, not retained)
  class pmu_reg_scratch extends uvm_reg;
    `uvm_object_utils(pmu_reg_scratch)
    rand uvm_reg_field DATA;
    function new(string name = "pmu_reg_scratch");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    virtual function void build();
      DATA = uvm_reg_field::type_id::create("DATA");
      DATA.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 1);
    endfunction
  endclass

  class pmu_cpu_win_block extends uvm_reg_block;
    `uvm_object_utils(pmu_cpu_win_block)
    rand pmu_reg_scratch SCRATCH[4];
    function new(string name = "pmu_cpu_win_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction
    virtual function void build();
      default_map = create_map("map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);
      foreach (SCRATCH[i]) begin
        SCRATCH[i] = pmu_reg_scratch::type_id::create($sformatf("SCRATCH%0d", i));
        SCRATCH[i].configure(this);
        SCRATCH[i].build();
        default_map.add_reg(SCRATCH[i], 4 * i, "RW");
      end
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class pmu_reg_block extends uvm_reg_block;
    `uvm_object_utils(pmu_reg_block)

    rand pmu_reg_id         ID;
    rand pmu_reg_ctrl       CTRL;
    rand pmu_reg_status     STATUS;
    rand pmu_reg_dvfs       DVFS;
    rand pmu_reg_wake_mask  WAKE_MASK;
    rand pmu_reg_wake_cause WAKE_CAUSE;
    rand pmu_reg_seq_delay  SEQ_DELAY;
    rand pmu_reg_pd_count   PD_COUNT;
    rand pmu_cpu_win_block  CPU_WIN;

    function new(string name = "pmu_reg_block");
      super.new(name, build_coverage(UVM_CVR_FIELD_VALS));
    endfunction

    // base_addr: where the PMU sits on the AXI4-Lite bus
    virtual function void build(uvm_reg_addr_t base_addr = 'h0);
      default_map = create_map("default_map", base_addr, 4, UVM_LITTLE_ENDIAN, 1);

      ID         = pmu_reg_id::type_id::create("ID");
      CTRL       = pmu_reg_ctrl::type_id::create("CTRL");
      STATUS     = pmu_reg_status::type_id::create("STATUS");
      DVFS       = pmu_reg_dvfs::type_id::create("DVFS");
      WAKE_MASK  = pmu_reg_wake_mask::type_id::create("WAKE_MASK");
      WAKE_CAUSE = pmu_reg_wake_cause::type_id::create("WAKE_CAUSE");
      SEQ_DELAY  = pmu_reg_seq_delay::type_id::create("SEQ_DELAY");
      PD_COUNT   = pmu_reg_pd_count::type_id::create("PD_COUNT");

      ID.configure(this);         ID.build();
      CTRL.configure(this);       CTRL.build();
      STATUS.configure(this);     STATUS.build();
      DVFS.configure(this);       DVFS.build();
      WAKE_MASK.configure(this);  WAKE_MASK.build();
      WAKE_CAUSE.configure(this); WAKE_CAUSE.build();
      SEQ_DELAY.configure(this);  SEQ_DELAY.build();
      PD_COUNT.configure(this);   PD_COUNT.build();

      default_map.add_reg(ID,         'h000, "RO");
      default_map.add_reg(CTRL,       'h004, "RW");
      default_map.add_reg(STATUS,     'h008, "RO");
      default_map.add_reg(DVFS,       'h00C, "RW");
      default_map.add_reg(WAKE_MASK,  'h010, "RW");
      default_map.add_reg(WAKE_CAUSE, 'h014, "RW");
      default_map.add_reg(SEQ_DELAY,  'h018, "RW");
      default_map.add_reg(PD_COUNT,   'h01C, "RO");

      CPU_WIN = pmu_cpu_win_block::type_id::create("CPU_WIN");
      CPU_WIN.configure(this);
      CPU_WIN.build();
      default_map.add_submap(CPU_WIN.default_map, 'h100);

      // Built-in test exclusions:
      //  * DVFS: writing the reserved OPP value returns SLVERR by design, so
      //    a walking-ones bit bash cannot pass; it is covered by pmu_err_test.
      uvm_resource_db#(bit)::set({"REG::", DVFS.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
      //  * CPU_WIN: accessible only while PD_CPU runs; the test sequence keeps
      //    the CPU running, so these are included in the built-in tests.

      lock_model();
    endfunction

    // True if `rg` lives in the switchable power domain
    function bit in_pd_cpu(uvm_reg rg);
      return (rg != null) && (rg.get_parent() == CPU_WIN);
    endfunction

  endclass

endpackage
