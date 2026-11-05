// pmu_state_tracker.svh - current reference-model state, shared with sequences
//
// Updated only by the scoreboard (from observed pins). Virtual sequences use
// it to wait for power states without peeking at DUT internals.
class pmu_state_tracker extends uvm_object;
  `uvm_object_utils(pmu_state_tracker)

  pmu_state_e    cur = PMU_RESET;
  pmu_state_e    last_stable = PMU_RESET;
  bit [1:0]      opp;
  event          changed;
  virtual pwr_if vif;   // for cycle-based timeouts

  function new(string name = "pmu_state_tracker");
    super.new(name);
  endfunction

  function void set(pmu_state_e s);
    if (s != cur) begin
      cur = s;
      if (pmu_is_stable(s)) last_stable = s;
      -> changed;
    end
  endfunction

  // Wait until the model is in state s; returns 0 on timeout.
  task wait_for(pmu_state_e s, int unsigned max_cycles, output bit ok);
    bit got = 0;
    fork begin               // isolate: disable fork only kills our children
      fork
        begin
          while (cur != s) @(changed);
          got = 1;
        end
        repeat (max_cycles) @(posedge vif.clk);
      join_any
      disable fork;
    end join
    ok = got;
  endtask

  // Wait until the model leaves state s; returns 0 on timeout.
  task wait_leave(pmu_state_e s, int unsigned max_cycles, output bit ok);
    bit got = 0;
    fork begin
      fork
        begin
          while (cur == s) @(changed);
          got = 1;
        end
        repeat (max_cycles) @(posedge vif.clk);
      join_any
      disable fork;
    end join
    ok = got;
  endtask

endclass
