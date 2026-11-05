#!/usr/bin/env bash
# run_vcs.sh - Synopsys VCS. Options: see common.sh
#   VCS_UVM : -ntb_opts value (default uvm-ieee-2020; uvm-1.2 also works)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
BUILD_DIR="${BUILD_DIR:-$HERE/../out/vcs/bug${BUG}}"
mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
LOG="$BUILD_DIR/${TEST}_s${SEED}.log"
if [ "$REBUILD" = 1 ] || [ ! -x simv ]; then
  vcs -full64 -sverilog -ntb_opts "${VCS_UVM:-uvm-ieee-2020}" -timescale=1ns/1ps \
      -debug_access+r -cm line+cond+fsm+tgl+assert -top pmu_tb_top \
      -F "$FILELIST" "${EXTRA_FL[@]}" "${COMMON_DEFS[@]}" -l compile.log -o simv
fi
RUN=(./simv +ntb_random_seed="$SEED" -cm line+cond+fsm+tgl+assert -cm_name "${TEST}_s${SEED}" -l "$LOG")
[ "$GUI" = 1 ] && RUN+=(-gui)
set +e; "${RUN[@]}" "${RUN_PLUSARGS[@]}"; RC=$?; set -e
check_log "$LOG" $RC
