#!/bin/sh
# Elaborate PD_CPU (the in-house CPU domain: pd_cpu -> cpu_top -> core, caches,
# AXI mux, SRAM wrappers, boundary synchronizers, mtime crossing) with Yosys and
# generate the OFF-state corruption model. The source list is taken from
# rtl/files.f (every file is read; Yosys keeps only the modules under pd_cpu),
# so a module added to PD_CPU is covered automatically.
# sv2v converts the SystemVerilog (packages, structs, module-header imports)
# into Verilog that Yosys 0.33 reads; names of variables and instances are kept.
set -e
OUT=${1:-build/corrupt}
mkdir -p "$OUT"
SRCS=$(grep -v '^+' rtl/files.f | grep -v '^ *$')
sv2v -DSYNTHESIS -Irtl/include --top=pd_cpu $SRCS > "$OUT/pd_cpu_sv2v.v"
yosys -q -p "read_verilog -DSYNTHESIS $OUT/pd_cpu_sv2v.v; \
  hierarchy -check -top pd_cpu; proc; write_json $OUT/pd_cpu.json"
python3 scripts/gen_corrupt_model.py "$OUT/pd_cpu.json" pd_cpu "$OUT/pd_cpu_corrupt.svh"
