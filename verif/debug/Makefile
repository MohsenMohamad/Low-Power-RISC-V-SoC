# Debug-block testbenches (SystemVerilog, Verilator --timing).
#
#   make list-tests                 print test names
#   make run-test TEST=<t> SEED=<n> build (if needed) and run one test
#   make test                       every test with SEED (default 1)
#   make build                      compile all testbenches
#
# Test <blk>_<name> runs testbench tb_<blk>. Each run writes
# $(OUT)/<test>_s<seed>.log and the coverage file <test>_s<seed>.dat.
ROOT      := $(abspath ../..)
BUILD     ?= $(ROOT)/build/verif_debug
OUT       ?= $(BUILD)/runs
VERILATOR ?= verilator
SEED      ?= 1
TEST      ?= trace_rand

RTL_F   := $(ROOT)/rtl/debug/dbg_files.f
RTL     := $(addprefix $(ROOT)/rtl/debug/,$(shell grep -v '^//' $(RTL_F)))
COMMON  := common/dbg_axil_if.sv common/dbg_axil_sva.sv common/dbg_tb_pkg.sv
TBS     := trace evcnt errlog wdt subsys
TESTS   := trace_rand trace_pwroff evcnt_rand evcnt_pwr errlog_rand wdt_rand wdt_lock subsys_smoke subsys_wdt_chain

VFLAGS  := --binary --timing --assert --coverage-line --coverage-user --coverage-toggle \
           -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC \
           --x-assign unique --x-initial unique -O2 -j 4 \
           $(ROOT)/rtl/debug/lint.vlt

tb_srcs = $(wildcard $(1)/*.sv)

.PHONY: list-tests run-test test build clean $(TBS)
list-tests:
	@for t in $(TESTS); do echo $$t; done

build: $(foreach t,$(TBS),$(BUILD)/tb_$(t)/Vtb_$(t))

define TB_RULE
$(BUILD)/tb_$(1)/Vtb_$(1): $(RTL) $(COMMON) $(call tb_srcs,$(1))
	@mkdir -p $(BUILD)/tb_$(1)
	$(VERILATOR) $(VFLAGS) --top-module tb_$(1) -Mdir $(BUILD)/tb_$(1) -o Vtb_$(1) \
	    $(RTL) $(COMMON) $(call tb_srcs,$(1)) > $(BUILD)/tb_$(1)/build.log 2>&1 \
	    || (cat $(BUILD)/tb_$(1)/build.log; exit 1)
$(1): $(BUILD)/tb_$(1)/Vtb_$(1)
endef
$(foreach t,$(TBS),$(eval $(call TB_RULE,$(t))))

TB_OF = $(firstword $(subst _, ,$(1)))

run-test: $(BUILD)/tb_$(call TB_OF,$(TEST))/Vtb_$(call TB_OF,$(TEST))
	@mkdir -p $(OUT)
	@$< +TEST=$(TEST) +seed=$(SEED) +verilator+seed+$(SEED) \
	    +verilator+coverage+file+$(OUT)/$(TEST)_s$(SEED).dat $(PLUSARGS) \
	    > $(OUT)/$(TEST)_s$(SEED).log 2>&1; rc=$$?; \
	  tail -3 $(OUT)/$(TEST)_s$(SEED).log; \
	  grep -q '^TEST PASSED' $(OUT)/$(TEST)_s$(SEED).log && [ $$rc -eq 0 ]

test:
	@fail=0; for t in $(TESTS); do \
	  echo "== $$t seed $(SEED)"; \
	  $(MAKE) --no-print-directory run-test TEST=$$t SEED=$(SEED) || fail=1; \
	done; exit $$fail

clean:
	rm -rf $(BUILD)
