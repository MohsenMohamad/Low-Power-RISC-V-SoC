#!/usr/bin/env bash
# run_xrun.sh - Cadence Xcelium. Options: see common.sh
#   XRUN_UVMHOME : UVM library for -uvmhome (default CDNS-IEEE = IEEE 1800.2;
#                  CDNS-1.2 or a path to an Accellera kit also work)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
BUILD_DIR="${BUILD_DIR:-$HERE/../out/xrun/bug${BUG}}"
mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
LOG="$BUILD_DIR/${TEST}_s${SEED}.log"
OPTS=(-64bit -sv -uvm -uvmhome "${XRUN_UVMHOME:-CDNS-IEEE}" -timescale 1ns/1ps
      -access +r -coverage functional -covoverwrite -covtest "${TEST}_s${SEED}"
      -top pmu_tb_top -F "$FILELIST" "${EXTRA_FL[@]}" "${COMMON_DEFS[@]}"
      -svseed "$SEED" -l "$LOG")
[ "$REBUILD" = 1 ] && OPTS+=(-clean)
[ "$GUI" = 1 ] && OPTS+=(-gui -linedebug)
set +e; xrun "${OPTS[@]}" "${RUN_PLUSARGS[@]}"; RC=$?; set -e
check_log "$LOG" $RC
