# Debug-block unit testbenches (SystemVerilog, class-based constrained random,
# SVA; Verilator --timing). Run by scripts/run_dbg.py (make dbg-unit at the top
# level), which records one result per test and seed and checks them against
# dv/regress/dbg_unit.required.
#
#   make build                 compile every testbench (trace once per depth)
#
# Test <blk>_<name> runs testbench tb_<blk>; the trace tests run at every
# supported buffer depth (tb_trace_d<depth>, DEPTH = 16, 32, 64, 128).
ROOT      := $(abspath ../..)
BUILD     ?= $(ROOT)/build/dbg_unit
VERILATOR ?= verilator

RTL     := $(addprefix $(ROOT)/,rtl/tech/tech_sync.sv rtl/tech/tech_ram_2c.sv rtl/common/rst_sync.sv \
             $(filter rtl/debug/%,$(shell grep -v '^+' $(ROOT)/rtl/files.f)))
COMMON  := common/dbg_axil_if.sv common/dbg_axil_sva.sv common/dbg_tb_pkg.sv
DEPTHS  := 16 32 64 128
TBS     := evcnt errlog wdt subsys neg

VFLAGS  := --binary --timing --assert --coverage-line --coverage-user --coverage-toggle \
           -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC \
           --x-assign unique --x-initial unique -O2 -j 4 $(ROOT)/lint/verilator.vlt

tb_srcs = $(wildcard $(1)/*.sv)

.PHONY: build clean
build: $(foreach t,$(TBS),$(BUILD)/tb_$(t)/Vtb_$(t)) $(foreach d,$(DEPTHS),$(BUILD)/tb_trace_d$(d)/Vtb_trace)

define TB_RULE
$(BUILD)/tb_$(1)/Vtb_$(1): $(RTL) $(COMMON) $(call tb_srcs,$(1))
	@mkdir -p $(BUILD)/tb_$(1)
	$(VERILATOR) $(VFLAGS) --top-module tb_$(1) -Mdir $(BUILD)/tb_$(1) -o Vtb_$(1) \
	    $(RTL) $(COMMON) $(call tb_srcs,$(1)) > $(BUILD)/tb_$(1)/build.log 2>&1 \
	    || (tail -40 $(BUILD)/tb_$(1)/build.log; exit 1)
endef
$(foreach t,$(TBS),$(eval $(call TB_RULE,$(t))))

define TRACE_RULE
$(BUILD)/tb_trace_d$(1)/Vtb_trace: $(RTL) $(COMMON) $(call tb_srcs,trace)
	@mkdir -p $(BUILD)/tb_trace_d$(1)
	$(VERILATOR) $(VFLAGS) --top-module tb_trace -GDEPTH=$(1) -Mdir $(BUILD)/tb_trace_d$(1) -o Vtb_trace \
	    $(RTL) $(COMMON) $(call tb_srcs,trace) > $(BUILD)/tb_trace_d$(1)/build.log 2>&1 \
	    || (tail -40 $(BUILD)/tb_trace_d$(1)/build.log; exit 1)
endef
$(foreach d,$(DEPTHS),$(eval $(call TRACE_RULE,$(d))))

clean:
	rm -rf $(BUILD)
