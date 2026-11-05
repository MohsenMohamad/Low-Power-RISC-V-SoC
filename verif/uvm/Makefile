# -----------------------------------------------------------------------------
# PMU UVM environment - front end for the run scripts
#
#   make run       SIM=<verilator|xrun|questa|vcs> TEST=<test> SEED=<n|random>
#   make regress   SIM=...  every test in TESTS with SEEDS seeds each
#   make selfcheck SIM=...  checker self-test: each stub BUG_MODE must FAIL
#   make bundle            single-file EDA Playground bundle (bundle/)
#   make clean
#
# SEED=random picks a new seed (printed in the log name).
# Extra plusargs: PLUSARGS="+UVM_VERBOSITY=UVM_HIGH +PMU_ITERS=20"
# -----------------------------------------------------------------------------
SIM      ?= verilator
TEST     ?= pmu_smoke_test
SEED     ?= 1
BUG      ?= 0
SEEDS    ?= 1 2 3
PLUSARGS ?=
TESTS    ?= pmu_smoke_test pmu_ral_test pmu_rand_reg_test pmu_rand_pwr_test \
            pmu_pwr_matrix_test pmu_err_test pmu_full_test

SCRIPT := scripts/run_$(SIM).sh

.PHONY: run regress selfcheck bundle clean

run:
	$(SCRIPT) -t $(TEST) -s $(SEED) -b $(BUG) -- $(PLUSARGS)

regress:
	@fail=0; for t in $(TESTS); do for s in $(SEEDS); do \
	  $(SCRIPT) -t $$t -s $$s -- $(PLUSARGS) || fail=$$((fail+1)); \
	done; done; \
	echo "regression: $$fail failing run(s)"; test $$fail -eq 0

# Each injected stub bug must be caught (the run must FAIL).
selfcheck:
	@ok=0; for b in 1 2 3; do \
	  if $(SCRIPT) -t pmu_full_test -s 1 -b $$b > /dev/null 2>&1; then \
	    echo "selfcheck: BUG_MODE=$$b NOT detected"; ok=1; \
	  else echo "selfcheck: BUG_MODE=$$b detected"; fi; \
	done; test $$ok -eq 0

bundle:
	python3 scripts/mk_bundle.py

clean:
	rm -rf out
