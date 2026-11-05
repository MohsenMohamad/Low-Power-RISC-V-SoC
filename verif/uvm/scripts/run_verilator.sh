#!/usr/bin/env bash
# run_verilator.sh - Verilator (>= 5.036, --timing). Options: see common.sh
#   UVM_HOME  : src/ directory of a UVM kit Verilator can compile, e.g. the
#               IEEE 1800.2-2020 (2020.3.1) kit with Verilator patches from
#               https://github.com/chipsalliance/uvm-verilator (uvm-2020-3.1-vlt)
#   VERILATOR : verilator executable (default: verilator on PATH)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
: "${UVM_HOME:?set UVM_HOME to the uvm-verilator src/ directory}"
VERILATOR="${VERILATOR:-verilator}"
BUILD_DIR="${BUILD_DIR:-$HERE/../out/verilator/bug${BUG}}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
mkdir -p "$BUILD_DIR"
if [ "$REBUILD" = 1 ] || [ ! -x "$BUILD_DIR/Vpmu_tb_top" ]; then
  echo "[run_verilator] building in $BUILD_DIR"
  "$VERILATOR" --binary --timing -j "$JOBS" \
    --top-module pmu_tb_top --timescale 1ns/1ps \
    -Wno-fatal -Wno-lint -Wno-style \
    --assert --coverage-user \
    +define+UVM_NO_DPI "${COMMON_DEFS[@]}" \
    +incdir+"$UVM_HOME" "$UVM_HOME/uvm_pkg.sv" \
    -F "$FILELIST" "${EXTRA_FL[@]}" \
    -Mdir "$BUILD_DIR" -o Vpmu_tb_top \
    > "$BUILD_DIR/build.log" 2>&1 || { tail -50 "$BUILD_DIR/build.log"; echo "[run_verilator] BUILD FAILED"; exit 1; }
fi
LOG="$BUILD_DIR/${TEST}_s${SEED}.log"
echo "[run_verilator] $TEST seed=$SEED bug=$BUG -> $LOG"
[ "$GUI" = 1 ] && echo "[run_verilator] -g: rebuild with DEFINES=+define+PMU_DUMP for a VCD"
set +e
( cd "$BUILD_DIR" && ./Vpmu_tb_top +verilator+seed+"$SEED" "${RUN_PLUSARGS[@]}" ) > "$LOG" 2>&1
RC=$?
set -e
[ -f "$BUILD_DIR/coverage.dat" ] && mv -f "$BUILD_DIR/coverage.dat" "$BUILD_DIR/${TEST}_s${SEED}.cov.dat"
# SVA failures ($error) are reported by Verilator as %Error
grep -q "^%Error" "$LOG" && RC=1
check_log "$LOG" $RC
