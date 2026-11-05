# SystemVerilog constrained-random cache testbenches (Verilator --timing).
# Constrained randomize() needs an SMT solver (z3) on PATH.
#
#   make            build and run both benches for all SEEDS
#   make SEEDS="1 2 3" N=20000

VERILATOR ?= verilator
BUILD     ?= $(CURDIR)/../../build/cachetest
ROOT      := $(abspath $(CURDIR)/../..)
SEEDS     ?= 1 2 3 4 5 6 7 8
N         ?= 8000

COMMON := $(ROOT)/rtl/tech/tech_sram_sp.sv $(ROOT)/dv/cache/cache_ifs.sv $(ROOT)/dv/cache/cache_tb_pkg.sv
VFLAGS := --binary --timing --assert --coverage -Wno-fatal -j 4

.PHONY: all run build
all: run

build: $(BUILD)/dc/Vtb_dcache $(BUILD)/ic/Vtb_icache

$(BUILD)/dc/Vtb_dcache: $(COMMON) $(ROOT)/rtl/cache/dcache.sv tb_dcache.sv
	@mkdir -p $(BUILD)/dc
	$(VERILATOR) $(VFLAGS) --top-module tb_dcache -Mdir $(BUILD)/dc/obj \
	  $(ROOT)/rtl/tech/tech_sram_sp.sv $(ROOT)/rtl/cache/dcache.sv $(ROOT)/dv/cache/cache_ifs.sv \
	  $(ROOT)/dv/cache/cache_tb_pkg.sv $(ROOT)/dv/cache/tb_dcache.sv -o $@ > $(BUILD)/dc/build.log 2>&1 \
	  || (tail -30 $(BUILD)/dc/build.log; exit 1)

$(BUILD)/ic/Vtb_icache: $(COMMON) $(ROOT)/rtl/cache/icache.sv tb_icache.sv
	@mkdir -p $(BUILD)/ic
	$(VERILATOR) $(VFLAGS) --top-module tb_icache -Mdir $(BUILD)/ic/obj \
	  $(ROOT)/rtl/tech/tech_sram_sp.sv $(ROOT)/rtl/cache/icache.sv $(ROOT)/dv/cache/cache_ifs.sv \
	  $(ROOT)/dv/cache/cache_tb_pkg.sv $(ROOT)/dv/cache/tb_icache.sv -o $@ > $(BUILD)/ic/build.log 2>&1 \
	  || (tail -30 $(BUILD)/ic/build.log; exit 1)

run: build
	python3 $(ROOT)/scripts/run_cachetest.py --build $(BUILD) --seeds "$(SEEDS)" --n $(N)
