#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_verilator.sh - build and run the PMU UVM environment with Verilator
#
# Needs Verilator >= 5.036 with --timing, and a UVM library Verilator can
# compile: the Accellera IEEE 1800.2-2020 (2020.3.1) kit with the Verilator
# patches from https://github.com/chipsalliance/uvm-verilator
# (branch uvm-2020-3.1-vlt). Point UVM_HOME at its src/ directory.
#
# usage: run_verilator.sh [-t TEST] [-s SEED] [-b BUG_MODE] [-n ITERS] [-c] [-- extra plusargs]
#   -t  UVM test name                      (default pmu_smoke_test)
#   -s  random seed, or "random"           (default 1)
#   -b  stub BUG_MODE for checker self-test (default 0 = correct DUT)
#   -n  +PMU_ITERS value
#   -c  force rebuild
# Environment: UVM_HOME (required), VERILATOR (default verilator), BUILD_DIR,
#              EXTRA_F (extra -F filelist, e.g. the PMU power SVA), DEFINES
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST=pmu_smoke_test
SEED=1
BUG=0
ITERS=""
REBUILD=0
while getopts "t:s:b:n:c" o; do
  case "$o" in
    t) TEST="$OPTARG" ;;
    s) SEED="$OPTARG" ;;
    b) BUG="$OPTARG" ;;
    n) ITERS="$OPTARG" ;;
    c) REBUILD=1 ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

: "${UVM_HOME:?set UVM_HOME to the uvm-verilator src/ directory}"
VERILATOR="${VERILATOR:-verilator}"
BUILD_DIR="${BUILD_DIR:-$HERE/../out/verilator/bug${BUG}}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
[ "$SEED" = "random" ] && SEED=$(( (RANDOM << 15) | RANDOM ))

EXTRA_ARGS=()
[ -n "${EXTRA_F:-}" ] && EXTRA_ARGS+=(-F "$EXTRA_F")
# shellcheck disable=SC2206
[ -n "${DEFINES:-}" ] && EXTRA_ARGS+=(${DEFINES})

if [ "$REBUILD" = 1 ] || [ ! -x "$BUILD_DIR/Vpmu_tb_top" ]; then
  mkdir -p "$BUILD_DIR"
  "$VERILATOR" --binary --timing -j "$JOBS" \
    --top-module pmu_tb_top --timescale 1ns/1ps \
    -Wno-fatal -Wno-lint -Wno-style -Wno-SYMRSVDWORD -Wno-ZERODLY \
    --assert --coverage-user \
    +define+UVM_NO_DPI +define+PMU_STUB_BUG_MODE="$BUG" \
    +incdir+"$UVM_HOME" "$UVM_HOME/uvm_pkg.sv" \
    -F "$HERE/pmu_uvm.f" "${EXTRA_ARGS[@]}" \
    -Mdir "$BUILD_DIR" -o Vpmu_tb_top \
    > "$BUILD_DIR/build.log" 2>&1 || { tail -50 "$BUILD_DIR/build.log"; exit 1; }
fi

RUN_ARGS=(+UVM_TESTNAME="$TEST" +verilator+seed+"$SEED" +UVM_NO_RELNOTES)
[ -n "$ITERS" ] && RUN_ARGS+=(+PMU_ITERS="$ITERS")
LOG="$BUILD_DIR/${TEST}_s${SEED}.log"
echo "[run_verilator] $TEST seed=$SEED bug=$BUG -> $LOG"
set +e
( cd "$BUILD_DIR" && ./Vpmu_tb_top "${RUN_ARGS[@]}" "$@" ) > "$LOG" 2>&1
RC=$?
set -e
grep -E "TEST (PASSED|FAILED)|UVM_(ERROR|FATAL) :" "$LOG" | tail -4 || true
if [ $RC -ne 0 ] || ! grep -q "TEST PASSED" "$LOG"; then
  echo "[run_verilator] FAIL (rc=$RC)"; exit 1
fi
echo "[run_verilator] PASS"
