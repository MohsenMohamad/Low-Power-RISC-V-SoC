#!/usr/bin/env bash
# run_questa.sh - Siemens Questa. Options: see common.sh
#   UVM_HOME : UVM kit to compile (default: the IEEE 1800.2-2020 kit shipped
#              with Questa if found, else $MTI_HOME/verilog_src/uvm-1.2)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
BUILD_DIR="${BUILD_DIR:-$HERE/../out/questa/bug${BUG}}"
mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
if [ -z "${UVM_HOME:-}" ]; then
  MTI_HOME="${MTI_HOME:-$(dirname "$(dirname "$(command -v vsim)")")}"
  for d in "$MTI_HOME"/verilog_src/1800.2-2020* "$MTI_HOME"/verilog_src/uvm-1.2; do
    [ -d "$d/src" ] && { UVM_HOME="$d"; break; }
  done
fi
: "${UVM_HOME:?cannot find a UVM kit; set UVM_HOME}"
LOG="$BUILD_DIR/${TEST}_s${SEED}.log"
if [ "$REBUILD" = 1 ] || [ ! -d work ]; then
  rm -rf work; vlib work
  vlog -sv -mfcu -timescale 1ns/1ps +cover=f +acc=npr -l compile.log \
       +define+UVM_NO_DPI +incdir+"$UVM_HOME/src" "$UVM_HOME/src/uvm_pkg.sv" \
       -F "$FILELIST" "${EXTRA_FL[@]}" "${COMMON_DEFS[@]}"
fi
VSIM=(vsim -sv_seed "$SEED" -coverage -l "$LOG" work.pmu_tb_top "${RUN_PLUSARGS[@]}")
if [ "$GUI" = 1 ]; then VSIM+=(-gui); else VSIM+=(-c -do "coverage save -onexit ${TEST}_s${SEED}.ucdb; run -all; quit -f"); fi
set +e; "${VSIM[@]}"; RC=$?; set -e
check_log "$LOG" $RC
