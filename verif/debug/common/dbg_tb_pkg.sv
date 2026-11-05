// Shared testbench classes for the debug blocks: randomised AXI4-Lite master
// BFM, clock configuration, result reporting.
package dbg_tb_pkg;

  // ------------------------------------------------------------------
  // Result reporting. Every testbench ends with report(), which prints
  // "TEST PASSED" or "TEST FAILED" (parsed by tools/regress.py).
  // ------------------------------------------------------------------
  int unsigned n_err = 0;
  int unsigned n_chk = 0;

  function automatic void check(bit cond, string what);
    n_chk++;
    if (!cond) begin
      n_err++;
      $display("[%0t] CHECK FAILED: %s", $time, what);
    end
  endfunction

  function automatic void check_eq(logic [31:0] got, logic [31:0] exp, string what);
    n_chk++;
    if (got !== exp) begin
      n_err++;
      $display("[%0t] CHECK FAILED: %s: got 0x%08x exp 0x%08x", $time, what, got, exp);
    end
  endfunction

  function automatic void report(string name, int unsigned seed);
    $display("RESULT test=%s seed=%0d checks=%0d errors=%0d", name, seed, n_chk, n_err);
    if (n_err == 0 && n_chk > 0) $display("TEST PASSED");
    else                         $display("TEST FAILED");
  endfunction

  // ------------------------------------------------------------------
  // Randomised clock periods (ps) so that every seed exercises a different
  // clk_aon / clk_cpu ratio and phase.
  // ------------------------------------------------------------------
  class clk_cfg;
    rand int unsigned aon_half_ps;
    rand int unsigned cpu_half_ps;
    rand int unsigned cpu_phase_ps;
    constraint c_rng {
      aon_half_ps inside {[3000:15000]};
      cpu_half_ps inside {[2000:20000]};
      cpu_phase_ps < 2 * cpu_half_ps;
      // DVFS points span 4x; keep the ratio within 1/6 .. 6
      cpu_half_ps * 6 >= aon_half_ps;
      aon_half_ps * 6 >= cpu_half_ps;
    }
  endclass

  // ------------------------------------------------------------------
  // AXI4-Lite master timing knobs (randomised per transaction).
  // ------------------------------------------------------------------
  // A batch of NT timings is randomised at once (one solver call) and
  // consumed one transaction at a time.
  localparam int unsigned NT = 16;
  class axil_timing_batch;
    rand bit [3:0] aw[NT], w[NT], b[NT], ar[NT], r[NT];
    constraint c_dly {
      foreach (aw[i]) {
        aw[i] dist {0 := 6, [1:3] := 3, [4:8] := 1};
        w[i]  dist {0 := 6, [1:3] := 3, [4:8] := 1};
        b[i]  dist {0 := 6, [1:3] := 3};
        ar[i] dist {0 := 6, [1:3] := 3};
        r[i]  dist {0 := 6, [1:3] := 3};
      }
    }
  endclass

  class axil_timing;
    int unsigned aw_dly, w_dly, b_dly, ar_dly, r_dly;
    axil_timing_batch bt = new();
    int unsigned k = NT;
    function int randomize_next();
      if (k == NT) begin
        if (bt.randomize() == 0) return 0;
        k = 0;
      end
      aw_dly = bt.aw[k]; w_dly = bt.w[k]; b_dly = bt.b[k]; ar_dly = bt.ar[k]; r_dly = bt.r[k];
      k++;
      return 1;
    endfunction
  endclass

  class axil_master;
    virtual dbg_axil_if vif;
    axil_timing tm;
    bit randomize_timing = 1'b1;
    int unsigned n_wr, n_rd, n_slverr;

    function new(virtual dbg_axil_if v);
      vif = v;
      tm  = new();
    endfunction

    task automatic init();
      vif.awvalid <= 1'b0; vif.wvalid <= 1'b0; vif.bready <= 1'b0;
      vif.arvalid <= 1'b0; vif.rready <= 1'b0;
      vif.awprot  <= 3'b000; vif.arprot <= 3'b000;
      vif.awaddr  <= '0; vif.araddr <= '0; vif.wdata <= '0; vif.wstrb <= 4'hF;
    endtask

    task automatic pick_timing();
      if (randomize_timing) begin
        if (tm.randomize_next() == 0) $fatal(1, "axil_timing randomize failed");
      end else begin
        tm.aw_dly = 0; tm.w_dly = 0; tm.b_dly = 0; tm.ar_dly = 0; tm.r_dly = 0;
      end
    endtask

    task automatic wait_clk(int unsigned n);
      repeat (n) @(posedge vif.clk);
    endtask

    task automatic drive_aw(logic [13:0] addr);
      wait_clk(tm.aw_dly);
      vif.awaddr <= addr; vif.awvalid <= 1'b1;
      do @(posedge vif.clk); while (!vif.awready);
      vif.awvalid <= 1'b0;
    endtask

    task automatic drive_w(logic [31:0] data, logic [3:0] strb);
      wait_clk(tm.w_dly);
      vif.wdata <= data; vif.wstrb <= strb; vif.wvalid <= 1'b1;
      do @(posedge vif.clk); while (!vif.wready);
      vif.wvalid <= 1'b0;
    endtask

    // Write; returns BRESP.
    task automatic write(input logic [13:0] addr, input logic [31:0] data,
                         output logic [1:0] resp, input logic [3:0] strb = 4'hF);
      pick_timing();
      fork
        drive_aw(addr);
        drive_w(data, strb);
      join
      wait_clk(tm.b_dly);
      vif.bready <= 1'b1;
      do @(posedge vif.clk); while (!vif.bvalid);
      resp = vif.bresp;
      vif.bready <= 1'b0;
      n_wr++;
      if (resp != 2'b00) n_slverr++;
    endtask

    // Read; returns RDATA and RRESP.
    task automatic read(input logic [13:0] addr, output logic [31:0] data,
                        output logic [1:0] resp);
      pick_timing();
      wait_clk(tm.ar_dly);
      vif.araddr <= addr; vif.arvalid <= 1'b1;
      do @(posedge vif.clk); while (!vif.arready);
      vif.arvalid <= 1'b0;
      wait_clk(tm.r_dly);
      vif.rready <= 1'b1;
      do @(posedge vif.clk); while (!vif.rvalid);
      data = vif.rdata;
      resp = vif.rresp;
      vif.rready <= 1'b0;
      n_rd++;
      if (resp != 2'b00) n_slverr++;
    endtask

    // Convenience wrappers that check for OKAY.
    task automatic wr(input logic [13:0] addr, input logic [31:0] data);
      logic [1:0] r;
      write(addr, data, r);
      check(r == 2'b00, $sformatf("write 0x%03x = 0x%08x got SLVERR", addr, data));
    endtask

    task automatic rd(input logic [13:0] addr, output logic [31:0] data);
      logic [1:0] r;
      read(addr, data, r);
      check(r == 2'b00, $sformatf("read 0x%03x got SLVERR", addr));
    endtask
  endclass

endpackage
