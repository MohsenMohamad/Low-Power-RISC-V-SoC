# common.sh - option parsing shared by the run_*.sh scripts (sourced)
#   -t TEST   UVM test (default pmu_smoke_test)
#   -s SEED   integer seed or "random" (default 1)
#   -b BUG    stub BUG_MODE for checker self-test (default 0)
#   -n ITERS  +PMU_ITERS
#   -c        force recompilation
#   -g        GUI / waveform dump where supported
#   --        everything after is passed to the simulator run as plusargs
# Environment: BUILD_DIR, EXTRA_F (extra -F filelist), DEFINES (+define+...)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST=pmu_smoke_test; SEED=1; BUG=0; ITERS=""; REBUILD=0; GUI=0
while getopts "t:s:b:n:cg" o; do
  case "$o" in
    t) TEST="$OPTARG" ;; s) SEED="$OPTARG" ;; b) BUG="$OPTARG" ;;
    n) ITERS="$OPTARG" ;; c) REBUILD=1 ;; g) GUI=1 ;;
    *) sed -n '2,10p' "$HERE/common.sh"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
PLUSARGS=("$@")
[ "$SEED" = "random" ] && SEED=$(( (RANDOM << 15) | RANDOM ))
FILELIST="$HERE/pmu_uvm.f"
COMMON_DEFS=(+define+PMU_STUB_BUG_MODE="$BUG")
# shellcheck disable=SC2206
[ -n "${DEFINES:-}" ] && COMMON_DEFS+=(${DEFINES})
EXTRA_FL=()
[ -n "${EXTRA_F:-}" ] && EXTRA_FL=(-F "$EXTRA_F")
RUN_PLUSARGS=(+UVM_TESTNAME="$TEST" +UVM_NO_RELNOTES)
[ -n "$ITERS" ] && RUN_PLUSARGS+=(+PMU_ITERS="$ITERS")
RUN_PLUSARGS+=("${PLUSARGS[@]}")

# Pass/fail from the log: the base test prints *** TEST PASSED/FAILED ***
check_log() {
  local log="$1" rc="$2"
  grep -E "TEST (PASSED|FAILED)|UVM_(ERROR|FATAL) :" "$log" | tail -4 || true
  if [ "$rc" -ne 0 ] || ! grep -q "TEST PASSED" "$log"; then
    echo "[$(basename "$0")] FAIL  $TEST seed=$SEED  ($log)"; return 1
  fi
  echo "[$(basename "$0")] PASS  $TEST seed=$SEED"
}
