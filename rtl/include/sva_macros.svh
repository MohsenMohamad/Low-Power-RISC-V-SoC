// -----------------------------------------------------------------------------
// sva_macros.svh - portable assertion macros
//
// The same assertion source is consumed by three tools with different SVA
// support levels:
//   * Verilator (simulation, SVA_ON defined): real concurrent SVA properties
//     (assert property / cover property with disable iff, |->, |=>).
//   * Yosys/SymbiYosys open-source frontend (FORMAL defined): it has no clocked
//     concurrent properties, so the macros expand to clocked immediate
//     assertions with $past(), which is semantically identical for the
//     single-cycle forms used here.
//   * Icarus Verilog (neither defined): assertions compile to nothing; the
//     Icarus runs are used for 4-state X-propagation checks instead.
//
// Forms:
//   `SVA_ASSERT(name, clk, rst_n, expr)          expr holds every cycle
//   `SVA_ASSERT_IMP(name, clk, rst_n, a, c)      a |-> c
//   `SVA_ASSERT_NXT(name, clk, rst_n, a, c)      a |=> c
//   `SVA_COVER(name, clk, rst_n, expr)           expr reachable
// -----------------------------------------------------------------------------
`ifndef SVA_MACROS_SVH
`define SVA_MACROS_SVH

`ifdef FORMAL
  `define SVA_ASSERT(name, clk, rst_n, expr) \
    always @(posedge clk) if (rst_n) name: assert (expr);
  `define SVA_ASSERT_IMP(name, clk, rst_n, a, c) \
    always @(posedge clk) if (rst_n) name: assert (!(a) || (c));
  `define SVA_ASSERT_NXT(name, clk, rst_n, a, c) \
    always @(posedge clk) if (rst_n && $past(rst_n) && $past(a)) name: assert (c);
  `define SVA_COVER(name, clk, rst_n, expr) \
    always @(posedge clk) if (rst_n) name: cover (expr);
`elsif SVA_ON
  `define SVA_ASSERT(name, clk, rst_n, expr) \
    name: assert property (@(posedge clk) disable iff (!(rst_n)) (expr)) \
      else $error("SVA %m: %s", `"expr`");
  `define SVA_ASSERT_IMP(name, clk, rst_n, a, c) \
    name: assert property (@(posedge clk) disable iff (!(rst_n)) (a) |-> (c)) \
      else $error("SVA %m: %s |-> %s", `"a`", `"c`");
  `define SVA_ASSERT_NXT(name, clk, rst_n, a, c) \
    name: assert property (@(posedge clk) disable iff (!(rst_n)) (a) |=> (c)) \
      else $error("SVA %m: %s |=> %s", `"a`", `"c`");
  `define SVA_COVER(name, clk, rst_n, expr) \
    name: cover property (@(posedge clk) disable iff (!(rst_n)) (expr));
`else
  `define SVA_ASSERT(name, clk, rst_n, expr)
  `define SVA_ASSERT_IMP(name, clk, rst_n, a, c)
  `define SVA_ASSERT_NXT(name, clk, rst_n, a, c)
  `define SVA_COVER(name, clk, rst_n, expr)
`endif

`endif
