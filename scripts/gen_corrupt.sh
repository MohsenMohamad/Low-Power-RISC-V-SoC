#!/bin/sh
# Elaborate PD_CPU with Yosys and generate the OFF-state corruption model.
set -e
OUT=${1:-build/corrupt}
mkdir -p "$OUT"
yosys -q -p "read_verilog -sv -DSYNTHESIS -Irtl/include third_party/picorv32/picorv32.v \
  rtl/tech/tech_sync.sv rtl/cpu/cpu_core_picorv32.sv rtl/cpu/pd_cpu.sv; \
  hierarchy -top pd_cpu; proc; write_json $OUT/pd_cpu.json"
python3 scripts/gen_corrupt_model.py "$OUT/pd_cpu.json" pd_cpu "$OUT/pd_cpu_corrupt.svh"
