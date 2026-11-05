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
# integration preview (PicoRV32 SoC + debug blocks, firmware fw/debug)
INTEG_TESTS := integ_drv integ_stress integ_crash_illegal integ_crash_misalign integ_hang

VFLAGS  := --binary --timing --assert --coverage-line --coverage-user --coverage-toggle \
           -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC \
           --x-assign unique --x-initial unique -O2 -j 4 \
           $(ROOT)/rtl/debug/lint.vlt

tb_srcs = $(wildcard $(1)/*.sv)

.PHONY: list-tests run-test test build clean integ integ-fw $(TBS)
list-tests:
	@for t in $(TESTS) $(INTEG_TESTS); do echo $$t; done

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

# ---------------- integration preview ----------------
S3_PLAT  := $(ROOT)/platform/picorv32
S3_RTL   := $(addprefix $(ROOT)/rtl/tech/,tc_sync.sv tc_rst_sync.sv tc_clk_gate.sv tc_clk_mux_gf.sv \
            tc_iso.sv tc_pwr_switch.sv tc_sram.sv tc_vreg.sv) $(ROOT)/third_party/picorv32/picorv32.v \
            $(addprefix $(S3_PLAT)/rtl/,pico_cache.sv bus_cdc.sv pico_pd_cpu.sv aon_uart.sv aon_timer.sv \
            aon_intc.sv aon_pmu.sv pico_soc.sv)
INTEG_SRC := integ/dbg_uart_pty_bridge.sv integ/tb_dbg_soc.sv integ/uart_pty.c
INTEG_BIN := $(BUILD)/integ/Vtb_dbg_soc
ROM_HEX  := $(ROOT)/build/fw/lpsoc-picorv32/rom.hex
APP_HEX  := $(ROOT)/build/fw_debug/lpsoc-picorv32-$(if $(shell command -v riscv64-unknown-elf-gcc),gcc,clang)/dbgapp.hex

integ: $(INTEG_BIN)
$(INTEG_BIN): $(RTL) $(S3_RTL) $(INTEG_SRC)
	@test -f $(S3_PLAT)/rtl/pico_soc.sv || { echo "SKIP: platform/picorv32 (Session 3) not present"; exit 1; }
	@mkdir -p $(BUILD)/integ
	$(VERILATOR) --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	    --timescale 1ns/1ps -O2 -j 4 --top-module tb_dbg_soc -Mdir $(BUILD)/integ -o Vtb_dbg_soc \
	    $(S3_PLAT)/lint.vlt $(ROOT)/rtl/debug/lint.vlt $(S3_RTL) $(RTL) $(INTEG_SRC) \
	    > $(BUILD)/integ/build.log 2>&1 || (tail -40 $(BUILD)/integ/build.log; exit 1)

integ-fw:
	$(MAKE) -C $(ROOT)/fw PLATFORM=lpsoc ARCH=picorv32 > /dev/null
	$(MAKE) -C $(ROOT)/fw/debug > /dev/null

ITER    ?= 24
integ_args = $(strip \
  $(if $(filter integ_drv,$(1)),+test=2) \
  $(if $(filter integ_stress,$(1)),+test=1 +iters=$(ITER) +flags=$(or $(FLAGS),0)) \
  $(if $(filter integ_crash_illegal,$(1)),+test=3) \
  $(if $(filter integ_crash_misalign,$(1)),+test=4) \
  $(if $(filter integ_hang,$(1)),+test=5))

TB_OF = $(firstword $(subst _, ,$(1)))

ifneq ($(filter integ_%,$(TEST)),)
run-test: integ integ-fw
	@mkdir -p $(OUT)
	@$(INTEG_BIN) +rom_hex=$(ROM_HEX) +ram_hex=$(APP_HEX) $(call integ_args,$(TEST)) +seed=$(SEED) \
	    +uart_log=$(OUT)/$(TEST)_s$(SEED).uart +timeout=$(or $(TIMEOUT),400000000) $(PLUSARGS) \
	    > $(OUT)/$(TEST)_s$(SEED).log 2>&1; rc=$$?; \
	  tail -2 $(OUT)/$(TEST)_s$(SEED).log; \
	  grep -q '^\[TB\] SIM RESULT: PASS' $(OUT)/$(TEST)_s$(SEED).log && [ $$rc -eq 0 ]
else
run-test: $(BUILD)/tb_$(call TB_OF,$(TEST))/Vtb_$(call TB_OF,$(TEST))
	@mkdir -p $(OUT)
	@$< +TEST=$(TEST) +seed=$(SEED) +verilator+seed+$(SEED) \
	    +verilator+coverage+file+$(OUT)/$(TEST)_s$(SEED).dat $(PLUSARGS) \
	    > $(OUT)/$(TEST)_s$(SEED).log 2>&1; rc=$$?; \
	  tail -3 $(OUT)/$(TEST)_s$(SEED).log; \
	  grep -q '^TEST PASSED' $(OUT)/$(TEST)_s$(SEED).log && [ $$rc -eq 0 ]
endif

build: integ integ-fw

test:
	@fail=0; for t in $(TESTS); do \
	  echo "== $$t seed $(SEED)"; \
	  $(MAKE) --no-print-directory run-test TEST=$$t SEED=$(SEED) || fail=1; \
	done; exit $$fail

clean:
	rm -rf $(BUILD)
