# Low-Power RISC-V SoC - build and verification entry points.
#
#   make lint        Verilator -Wall lint of all RTL
#   make cosim       random instruction streams in lockstep with Spike
#   make archtest    riscv-arch-test (rv32i_m: I, M, Zifencei, privilege)
#   make cachetest   SystemVerilog constrained-random cache testbenches
#   make coverage    merged functional + code coverage report
#   make test        all of the above
#
# Tool locations (override on the command line or via environment):
VERILATOR    ?= $(shell command -v verilator 2>/dev/null || echo /opt/verilator/bin/verilator)
VERILATOR_COV?= $(dir $(VERILATOR))verilator_coverage
SPIKE_PREFIX ?= /opt/spike
RV_PREFIX    ?= riscv64-unknown-elf-
ARCH_TEST_DIR?= third_party/riscv-arch-test
JOBS         ?= $(shell nproc)

# Regression sizes
COSIM_SEEDS  ?= 200
COSIM_LEN    ?= 3000

BUILD := build
RTL_PKG  := rtl/pkg/riscv_pkg.sv
RTL_SRCS := $(RTL_PKG) rtl/tech/tech_sram_sp.sv \
            rtl/core/core_alu.sv rtl/core/core_decoder.sv rtl/core/core_regfile.sv \
            rtl/core/core_muldiv.sv rtl/core/core_csr.sv rtl/core/core_fetch.sv rtl/core/core_top.sv \
            rtl/cache/icache.sv rtl/cache/dcache.sv rtl/bus/axil_mux2.sv rtl/cpu/cpu_top.sv

COSIM_BIN := $(BUILD)/cosim/obj/Vcosim
VFLAGS_COMMON := -O2 -Wno-fatal --assert -j $(JOBS)

.PHONY: all test lint cosim cosim-build archtest cachetest coverage clean

all: test

test: lint cosim archtest cachetest coverage

lint:
	$(VERILATOR) --lint-only -Wall --top-module cpu_top $(RTL_SRCS)
	@echo "LINT: clean"

# ---------------------------------------------------------------------------
# Spike lockstep co-simulation testbench (also runs riscv-arch-test ELFs)
# ---------------------------------------------------------------------------
cosim-build: $(COSIM_BIN)

$(COSIM_BIN): $(RTL_SRCS) dv/cosim/cpu_cov.sv dv/cosim/tb_main.cpp dv/cosim/spike_cosim.cpp \
              dv/cosim/spike_cosim.h dv/cosim/isa_cov.h dv/common/axil_mem.h dv/common/elf32.h
	@mkdir -p $(BUILD)/cosim/obj
	$(VERILATOR) --cc --exe --build $(VFLAGS_COMMON) --coverage --top-module cpu_top \
	  -GRAM_MASK=32\'hFFC00000 -Mdir $(BUILD)/cosim/obj \
	  $(RTL_SRCS) dv/cosim/cpu_cov.sv dv/cosim/tb_main.cpp dv/cosim/spike_cosim.cpp \
	  -CFLAGS "-O2 -std=c++17 -I$(SPIKE_PREFIX)/include -I$(CURDIR)/dv/cosim" \
	  -LDFLAGS "-L$(SPIKE_PREFIX)/lib -Wl,-rpath,$(SPIKE_PREFIX)/lib -lriscv" \
	  -o Vcosim > $(BUILD)/cosim/build.log 2>&1 || (tail -40 $(BUILD)/cosim/build.log; exit 1)

cosim: $(COSIM_BIN)
	python3 scripts/run_cosim.py --bin $(COSIM_BIN) --seeds $(COSIM_SEEDS) --length $(COSIM_LEN) \
	  --jobs $(JOBS) --out $(BUILD)/cosim/regress --rv-prefix $(RV_PREFIX)

archtest: $(COSIM_BIN)
	python3 scripts/run_archtest.py --bin $(COSIM_BIN) --suite $(ARCH_TEST_DIR) \
	  --spike $(SPIKE_PREFIX)/bin/spike --jobs $(JOBS) --out $(BUILD)/archtest --rv-prefix $(RV_PREFIX)

cachetest:
	$(MAKE) -C dv/cache VERILATOR=$(VERILATOR) BUILD=$(CURDIR)/$(BUILD)/cachetest

coverage:
	python3 scripts/cov_report.py --build $(BUILD) --verilator-coverage $(VERILATOR_COV) \
	  --out $(BUILD)/coverage

clean:
	rm -rf $(BUILD)
