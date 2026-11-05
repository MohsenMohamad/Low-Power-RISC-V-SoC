# Low-power RISC-V SoC - top-level build and verification flow.
#
#   make test        the complete open-source regression (scripts/regress.py): every
#                    step below, each checked against its required-test list; exits
#                    nonzero on any failure, missing or unknown test
#
# Individual steps (each exits nonzero on failure):
#   make toolchain   verify pinned tool versions (scripts/setup_toolchain.sh --check)
#   make lint        Verilator -Wall: SoC (with and without SVA) and the CPU subsystem
#   make fw          firmware (GCC 13.2): pm_test, boot_test, neg_fail
#   make sim         SoC, Verilator, pm_test, random OFF-state corruption + coverage goals
#   make sim-x       SoC, Icarus 4-state, pm_test, X OFF-state corruption + coverage goals
#   make boot        SoC, Verilator, stage-1 boot test + coverage goals
#   make boot-x      SoC, Icarus 4-state, stage-1 boot test + coverage goals
#   make sim-neg     negative tests of the SoC bench (defeated isolation, firmware FAIL, timeout)
#   make sim-pmu     PMU unit testbench (class-based constrained random, full coverage)
#   make cosim       CPU: directed + random programs in lockstep with Spike
#   make archtest    CPU: riscv-arch-test 3.9.1 (rv32i_m I, M, Zifencei, privilege)
#   make cachetest   caches / AXI mux: SystemVerilog constrained-random unit benches
#   make coverage    CPU coverage merge; fails on unwaived holes (dv/coverage_waivers.txt)
#   make formal      SymbiYosys proofs, each with a cover run
#   make mutation    mutation analysis; fails on surviving / unbuildable mutants
#   make selftest    negative tests of every checker, comparator and result parser
#   make clean
#
# Tool locations (setup: scripts/setup_toolchain.sh; versions: --check):
VERILATOR    ?= verilator
VERILATOR_COV?= $(dir $(shell command -v $(VERILATOR) 2>/dev/null))verilator_coverage
IVERILOG     ?= iverilog
VVP          ?= vvp
SBY          ?= sby
SV2V         ?= sv2v
PYTHON       ?= python3
SPIKE_PREFIX ?= /opt/spike
RV_PREFIX    ?= riscv64-unknown-elf-
ARCH_TEST_DIR?= third_party/riscv-arch-test
JOBS         ?= $(shell nproc)

# Regression sizes (the required-test lists in dv/regress/ match these defaults)
COSIM_SEEDS  ?= 200
COSIM_LEN    ?= 3000
CACHE_SEEDS  ?= 1 2 3 4 5 6 7 8
CACHE_N      ?= 8000
MUT_SEEDS    ?= 24
PMU_EPISODES ?= 400

BUILD := build

# ------------------------------------------------------------------ sources
RTL_FILES := $(shell grep -v '^+' rtl/files.f)
CPU_SRCS  := rtl/pkg/riscv_pkg.sv rtl/tech/tech_sram_sp.sv \
             rtl/core/core_alu.sv rtl/core/core_decoder.sv rtl/core/core_regfile.sv \
             rtl/core/core_muldiv.sv rtl/core/core_csr.sv rtl/core/core_fetch.sv rtl/core/core_top.sv \
             rtl/cache/icache.sv rtl/cache/dcache.sv rtl/bus/axil_mux2.sv rtl/cpu/cpu_top.sv
VLT_CFG   := lint/verilator.vlt
VLT_SVA   := lint/verilator_sva.vlt

FW_PROGS  := pm_test boot_test neg_fail
FW_HEX    := $(FW_PROGS:%=$(BUILD)/fw/%.hex)
CORRUPT   := $(BUILD)/corrupt/pd_cpu_corrupt.svh

VL_SIM_FLAGS := --binary --timing --timescale 1ns/1ps -j 0 -DSVA_ON --assert -Wno-fatal \
                -Wno-WIDTH -Wno-lint -Wno-style -Wno-MULTIDRIVEN
VL_TB := $(BUILD)/sim/vl/Vtb_soc
IV_TB := $(BUILD)/sim/iv/tb_soc.vvp
SOC_COV := $(PYTHON) scripts/check_soc_cov.py
CHECK   := $(PYTHON) scripts/check_results.py

COSIM_BIN := $(BUILD)/cosim/obj/Vcosim

.PHONY: test toolchain lint lint-soc lint-cpu fw corrupt sim sim-x boot boot-x sim-neg sim-pmu \
        cosim cosim-build archtest cachetest coverage formal mutation selftest clean

test:
	$(PYTHON) scripts/regress.py

toolchain:
	scripts/setup_toolchain.sh --check

# ------------------------------------------------------------------ lint
lint: lint-soc lint-cpu

lint-soc:
	$(VERILATOR) --lint-only -Wall --top-module soc_top $(VLT_CFG) -f rtl/files.f
	$(VERILATOR) --lint-only -Wall -DSVA_ON --assert --top-module soc_top $(VLT_CFG) $(VLT_SVA) -f rtl/files.f
	@echo "== SoC lint clean =="

lint-cpu:
	$(VERILATOR) --lint-only -Wall -Irtl/include --top-module cpu_top $(CPU_SRCS)
	$(VERILATOR) --lint-only -Wall -Irtl/include -DSVA_ON --assert --top-module cpu_top $(VLT_SVA) $(CPU_SRCS)
	@echo "== CPU lint clean =="

# ------------------------------------------------------------------ firmware
fw: $(FW_HEX)
$(BUILD)/fw/%.hex: fw/%.c fw/crt0.S fw/include/soc.h fw/link.ld fw/Makefile scripts/bin2hex.py
	$(MAKE) -C fw CROSS=$(RV_PREFIX) BUILD=../$(BUILD)/fw ../$(BUILD)/fw/$*.hex

# ------------------------------------------------------------------ OFF-state corruption model
corrupt: $(CORRUPT)
$(CORRUPT): scripts/gen_corrupt.sh scripts/gen_corrupt_model.py $(RTL_FILES) rtl/files.f
	./scripts/gen_corrupt.sh $(BUILD)/corrupt

# ------------------------------------------------------------------ SoC simulation
$(VL_TB): $(RTL_FILES) sim/tb_soc.sv $(CORRUPT)
	@mkdir -p $(BUILD)/sim
	$(VERILATOR) $(VL_SIM_FLAGS) --top-module tb_soc -Mdir $(BUILD)/sim/vl -o Vtb_soc \
	  -I$(BUILD)/corrupt $(VLT_CFG) -f rtl/files.f sim/tb_soc.sv > $(BUILD)/sim/vl_build.log 2>&1 \
	  || (tail -30 $(BUILD)/sim/vl_build.log; exit 1)

# Icarus simulates the sv2v translation of the RTL (it does not parse the CPU's
# packages / structs); the corruption model is generated from the same translation.
$(IV_TB): $(RTL_FILES) sim/tb_soc.sv $(CORRUPT)
	@mkdir -p $(BUILD)/sim/iv
	$(SV2V) -Irtl/include --top=soc_top $(RTL_FILES) > $(BUILD)/sim/iv/soc_sv2v.v
	$(IVERILOG) -g2012 -DCORRUPT_X -I$(BUILD)/corrupt -Irtl/include -s tb_soc -o $@ \
	  $(BUILD)/sim/iv/soc_sv2v.v sim/tb_soc.sv

# run_soc <simulator command> <rom> <log> <coverage file> <goals> [waivers]
define run_soc
	@mkdir -p $(BUILD)/sim
	$(1) +rom=$(2) +cov=$(4) > $(3) 2>&1; rc=$$?; grep -E "^\[uart\]|ABORTED|ERROR|TEST" $(3); \
	  if [ $$rc -ne 0 ] || ! grep -q "TEST PASSED" $(3); then echo "FAIL: $(3)"; exit 1; fi
	$(SOC_COV) --cov $(4) --goals $(5) $(if $(6),--waivers $(6))
endef

sim: $(VL_TB) $(BUILD)/fw/pm_test.hex
	$(call run_soc,$(VL_TB),$(BUILD)/fw/pm_test.hex,$(BUILD)/sim/pm_test_verilator.log,$(BUILD)/sim/cov_pm_test_verilator.txt,dv/regress/soc_pm_test.goals,dv/regress/soc_pm_test.waivers)

sim-x: $(IV_TB) $(BUILD)/fw/pm_test.hex
	$(call run_soc,$(VVP) -n $(IV_TB),$(BUILD)/fw/pm_test.hex,$(BUILD)/sim/pm_test_icarus.log,$(BUILD)/sim/cov_pm_test_icarus.txt,dv/regress/soc_pm_test.goals,dv/regress/soc_pm_test.waivers)

boot: $(VL_TB) $(BUILD)/fw/boot_test.hex
	$(call run_soc,$(VL_TB),$(BUILD)/fw/boot_test.hex,$(BUILD)/sim/boot_test_verilator.log,$(BUILD)/sim/cov_boot_test_verilator.txt,dv/regress/soc_boot_test.goals,)

boot-x: $(IV_TB) $(BUILD)/fw/boot_test.hex
	$(call run_soc,$(VVP) -n $(IV_TB),$(BUILD)/fw/boot_test.hex,$(BUILD)/sim/boot_test_icarus.log,$(BUILD)/sim/cov_boot_test_icarus.txt,dv/regress/soc_boot_test.goals,)

# Negative tests: each run must FAIL for the reason it was built to provoke.
sim-neg: $(VL_TB) $(IV_TB) $(FW_HEX)
	$(PYTHON) scripts/soc_neg.py --vl $(VL_TB) --iv "$(VVP) -n $(IV_TB)" --fw $(BUILD)/fw --out $(BUILD)/sim/neg

# ------------------------------------------------------------------ PMU unit test
$(BUILD)/sim/pmu/Vtb_pmu: rtl/aon/pmu.sv rtl/include/sva_macros.svh sim/pmu/tb_pmu.sv
	@mkdir -p $(BUILD)/sim/pmu
	$(VERILATOR) $(VL_SIM_FLAGS) --top-module tb_pmu -Mdir $(BUILD)/sim/pmu -o Vtb_pmu \
	  -Irtl/include rtl/aon/pmu.sv sim/pmu/tb_pmu.sv > $(BUILD)/sim/pmu/build.log 2>&1 \
	  || (tail -30 $(BUILD)/sim/pmu/build.log; exit 1)

sim-pmu: $(BUILD)/sim/pmu/Vtb_pmu
	$(BUILD)/sim/pmu/Vtb_pmu +episodes=$(PMU_EPISODES) > $(BUILD)/sim/pmu.log 2>&1; rc=$$?; \
	  sed -n '/== PMU unit coverage/,$$p' $(BUILD)/sim/pmu.log | head -40; \
	  if [ $$rc -ne 0 ] || ! grep -q "TEST PASSED" $(BUILD)/sim/pmu.log || grep -q "%Error" $(BUILD)/sim/pmu.log; \
	  then tail -5 $(BUILD)/sim/pmu.log; echo "FAIL: sim-pmu"; exit 1; fi

# ------------------------------------------------------------------ CPU: Spike lockstep co-simulation
# cpu_top alone, with a 4 MB test RAM window at 0x8000_0000 (sw/common/link.ld);
# the SoC uses the doc/SPEC.md map through pd_cpu parameters.
cosim-build: $(COSIM_BIN)
$(COSIM_BIN): $(CPU_SRCS) dv/cosim/cpu_cov.sv dv/cosim/tb_main.cpp dv/cosim/spike_cosim.cpp \
              dv/cosim/spike_cosim.h dv/cosim/isa_cov.h dv/common/axil_mem.h dv/common/elf32.h
	@mkdir -p $(BUILD)/cosim/obj
	$(VERILATOR) --cc --exe --build -O2 -Wno-fatal --assert -DSVA_ON -Irtl/include -j $(JOBS) --coverage --top-module cpu_top \
	  -GRAM_BASE=32\'h80000000 -GRAM_MASK=32\'hFFC00000 -Mdir $(BUILD)/cosim/obj \
	  $(CPU_SRCS) dv/cosim/cpu_cov.sv dv/cosim/tb_main.cpp dv/cosim/spike_cosim.cpp \
	  -CFLAGS "-O2 -std=c++17 -I$(SPIKE_PREFIX)/include -I$(CURDIR)/dv/cosim" \
	  -LDFLAGS "-L$(SPIKE_PREFIX)/lib -Wl,-rpath,$(SPIKE_PREFIX)/lib -lriscv" \
	  -o Vcosim > $(BUILD)/cosim/build.log 2>&1 || (tail -40 $(BUILD)/cosim/build.log; exit 1)

cosim: $(COSIM_BIN)
	rm -rf $(BUILD)/cosim/regress
	$(PYTHON) scripts/run_cosim.py --bin $(COSIM_BIN) --seeds $(COSIM_SEEDS) --length $(COSIM_LEN) \
	  --jobs $(JOBS) --out $(BUILD)/cosim/regress --rv-prefix $(RV_PREFIX); rc=$$?; \
	$(CHECK) --name cosim --results $(BUILD)/cosim/regress/results.json --required dv/regress/cosim.required \
	  && exit $$rc

archtest: $(COSIM_BIN)
	rm -rf $(BUILD)/archtest
	$(PYTHON) scripts/run_archtest.py --bin $(COSIM_BIN) --suite $(ARCH_TEST_DIR) \
	  --spike $(SPIKE_PREFIX)/bin/spike --jobs $(JOBS) --out $(BUILD)/archtest --rv-prefix $(RV_PREFIX); rc=$$?; \
	$(CHECK) --name archtest --results $(BUILD)/archtest/results.json --required dv/regress/archtest.required \
	  && exit $$rc

cachetest:
	rm -rf $(BUILD)/cachetest/dcache $(BUILD)/cachetest/icache $(BUILD)/cachetest/axilmux
	$(MAKE) -C dv/cache VERILATOR=$(VERILATOR) BUILD=$(CURDIR)/$(BUILD)/cachetest SEEDS="$(CACHE_SEEDS)" N=$(CACHE_N); rc=$$?; \
	$(CHECK) --name cachetest --results $(BUILD)/cachetest/results.json --required dv/regress/cachetest.required \
	  && exit $$rc

coverage:
	$(PYTHON) scripts/cov_report.py --build $(BUILD) --verilator-coverage $(VERILATOR_COV) \
	  --out $(BUILD)/coverage --waivers dv/coverage_waivers.txt

# ------------------------------------------------------------------ formal
formal:
	$(PYTHON) scripts/run_formal.py --sby $(SBY) --out $(BUILD)/formal; rc=$$?; \
	$(CHECK) --name formal --results $(BUILD)/formal/results.json --required dv/regress/formal.required \
	  && exit $$rc

# ------------------------------------------------------------------ mutation analysis
mutation:
	rm -rf $(BUILD)/mutation
	$(PYTHON) scripts/mutation.py --seeds $(MUT_SEEDS) --jobs $(JOBS) --verilator $(VERILATOR) \
	  --out $(CURDIR)/$(BUILD)/mutation; rc=$$?; \
	$(CHECK) --name mutation --results $(BUILD)/mutation/results.json --required dv/regress/mutation.required \
	  && exit $$rc

# ------------------------------------------------------------------ negative tests of the checkers
selftest:
	$(PYTHON) scripts/selftest.py --out $(BUILD)/selftest; rc=$$?; \
	$(CHECK) --name selftest --results $(BUILD)/selftest/results.json --required dv/regress/selftest.required \
	  && exit $$rc

clean:
	rm -rf $(BUILD)
