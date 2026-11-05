# Debug subsystem RTL: Verilator -Wall lint of every block and the wrapper.
#   make lint      lint all tops (fails on any warning)
VERILATOR ?= verilator
SRCS := lint.vlt $(shell grep -v "^//" dbg_files.f)
TOPS := dbg_trace dbg_evcnt dbg_errlog dbg_wdt dbg_subsys

.PHONY: lint list-tests run-test test
lint:
	@set -e; for t in $(TOPS); do \
	  echo "lint $$t"; \
	  $(VERILATOR) --lint-only -Wall --top-module $$t $(SRCS); \
	done
	@echo "LINT PASS"

# regression convention (doc/DEBUG_SPEC.md section 13)
list-tests:
	@echo lint
run-test:
	@$(MAKE) --no-print-directory lint
test: lint
