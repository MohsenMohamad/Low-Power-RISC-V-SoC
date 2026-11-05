# Low-power RISC-V SoC - top-level flow
#
#   make test        everything below (lint, firmware, simulations, formal)
#   make lint        Verilator -Wall on the RTL (with and without SVA)
#   make fw          boot-ROM firmware (clang + lld)
#   make sim         SoC simulation, Verilator, SVA on, random OFF-state corruption
#   make sim-x       SoC simulation, Icarus, 4-state X OFF-state corruption
#   make sim-neg     negative test: defeated isolation must be detected (both simulators)
#   make sim-pmu     PMU unit testbench (class-based constrained random)
#   make formal      SymbiYosys: PMU, DVFS clock mux, async FIFO (prove + cover)
#   make clean

VERILATOR ?= verilator
IVERILOG  ?= iverilog
VVP       ?= vvp
SBY       ?= sby
PYTHON    ?= python3

BUILD     := build
FW_HEX    := $(BUILD)/fw/pm_test.hex
CORRUPT   := $(BUILD)/corrupt/pd_cpu_corrupt.svh
RTL_FILES := $(shell grep -v '^+' rtl/files.f)
VLT_CFG   := lint/verilator.vlt
VLT_SVA   := lint/verilator_sva.vlt

VL_SIM_FLAGS := --binary --timing -j 0 -DSVA_ON --assert -Wno-fatal -Wno-WIDTH -Wno-lint \
                -Wno-style -Wno-MULTIDRIVEN

FORMAL_JOBS := pmu:prove pmu:cover dvfs_mux:prove dvfs_mux:cover async_fifo:prove async_fifo:cover

.PHONY: test lint fw sim sim-x sim-neg sim-pmu formal clean check-verilator

test: lint fw sim sim-x sim-neg sim-pmu formal
	@echo "== make test: all steps passed =="

# ------------------------------------------------------------------ lint
lint:
	$(VERILATOR) --lint-only -Wall --top-module soc_top $(VLT_CFG) -f rtl/files.f
	$(VERILATOR) --lint-only -Wall -DSVA_ON --assert --top-module soc_top $(VLT_CFG) $(VLT_SVA) -f rtl/files.f
	@echo "== lint clean =="

# ------------------------------------------------------------------ firmware
fw: $(FW_HEX)
$(FW_HEX): fw/crt0.S fw/pm_test.c fw/include/soc.h fw/link.ld scripts/bin2hex.py
	$(MAKE) -C fw BUILD=../$(BUILD)/fw

# ------------------------------------------------------------------ corruption model
$(CORRUPT): scripts/gen_corrupt.sh scripts/gen_corrupt_model.py rtl/cpu/pd_cpu.sv \
            rtl/cpu/cpu_core_picorv32.sv third_party/picorv32/picorv32.v rtl/tech/tech_sync.sv
	./scripts/gen_corrupt.sh $(BUILD)/corrupt

# ------------------------------------------------------------------ SoC simulation
$(BUILD)/sim/vl/Vtb_soc: $(RTL_FILES) sim/tb_soc.sv $(CORRUPT)
	@mkdir -p $(BUILD)/sim
	$(VERILATOR) $(VL_SIM_FLAGS) --top-module tb_soc -Mdir $(BUILD)/sim/vl -o Vtb_soc \
	  -I$(BUILD)/corrupt $(VLT_CFG) -f rtl/files.f sim/tb_soc.sv

$(BUILD)/sim/iv/tb_soc.vvp: $(RTL_FILES) sim/tb_soc.sv $(CORRUPT)
	@mkdir -p $(BUILD)/sim/iv
	$(IVERILOG) -g2012 -DCORRUPT_X -I$(BUILD)/corrupt -Irtl/include -s tb_soc -o $@ \
	  -c rtl/files.f sim/tb_soc.sv 2>&1 | grep -v "sorry: constant selects\|unique/unique0" || true
	@test -f $@

sim: fw $(BUILD)/sim/vl/Vtb_soc
	$(BUILD)/sim/vl/Vtb_soc | tee $(BUILD)/sim/soc_verilator.log
	@grep -q "TEST PASSED" $(BUILD)/sim/soc_verilator.log

sim-x: fw $(BUILD)/sim/iv/tb_soc.vvp
	$(VVP) -n $(BUILD)/sim/iv/tb_soc.vvp | tee $(BUILD)/sim/soc_icarus.log
	@grep -q "TEST PASSED" $(BUILD)/sim/soc_icarus.log

sim-neg: fw $(BUILD)/sim/vl/Vtb_soc $(BUILD)/sim/iv/tb_soc.vvp
	@echo "== negative test: isolation forced off while PD_CPU is unpowered =="
	@if $(BUILD)/sim/vl/Vtb_soc +break_iso > $(BUILD)/sim/neg_verilator.log 2>&1; then \
	  echo "FAIL: Verilator run did not detect broken isolation"; exit 1; \
	else grep -m1 -E "Assertion failed|ERROR" $(BUILD)/sim/neg_verilator.log; echo "OK: detected (Verilator)"; fi
	@if $(VVP) -n $(BUILD)/sim/iv/tb_soc.vvp +break_iso +timeout=6000000 > $(BUILD)/sim/neg_icarus.log 2>&1 \
	   && ! grep -q "ERROR" $(BUILD)/sim/neg_icarus.log; then \
	  echo "FAIL: Icarus run did not detect broken isolation"; exit 1; \
	else grep -m1 "ERROR" $(BUILD)/sim/neg_icarus.log; echo "OK: detected (Icarus, X propagation)"; fi

# ------------------------------------------------------------------ PMU unit test
check-verilator:
	@$(VERILATOR) --version | $(PYTHON) -c "import sys,re; v=re.search(r'(\d+)\.(\d+)', sys.stdin.read()); \
	  ok=(int(v[1]),int(v[2]))>=(5,28); print('Verilator', v[0], 'ok' if ok else '- need >= 5.028 for randomize() constraints'); sys.exit(0 if ok else 1)"

$(BUILD)/sim/pmu/Vtb_pmu: rtl/aon/pmu.sv rtl/include/sva_macros.svh sim/pmu/tb_pmu.sv
	@mkdir -p $(BUILD)/sim/pmu
	$(VERILATOR) $(VL_SIM_FLAGS) --top-module tb_pmu -Mdir $(BUILD)/sim/pmu -o Vtb_pmu \
	  -Irtl/include rtl/aon/pmu.sv sim/pmu/tb_pmu.sv

sim-pmu: check-verilator $(BUILD)/sim/pmu/Vtb_pmu
	$(BUILD)/sim/pmu/Vtb_pmu +episodes=400 | tee $(BUILD)/sim/pmu.log
	@grep -q "TEST PASSED" $(BUILD)/sim/pmu.log

# ------------------------------------------------------------------ formal
formal:
	@mkdir -p $(BUILD)/formal
	@set -e; for job in $(FORMAL_JOBS); do \
	  f=$${job%%:*}; t=$${job##*:}; \
	  rm -rf $(BUILD)/formal/$${f}_$$t; \
	  echo "== sby $$f.sby $$t"; \
	  (cd formal && $(SBY) -d ../$(BUILD)/formal/$${f}_$$t $$f.sby $$t > ../$(BUILD)/formal/$${f}_$$t.log 2>&1) \
	    || { grep -E "failed|Unreached|ERROR" $(BUILD)/formal/$${f}_$$t.log; exit 1; }; \
	  grep -E "DONE|successful proof|Reached cover" $(BUILD)/formal/$${f}_$$t.log | sed 's/.*\] //' | sort -u; \
	done

clean:
	rm -rf $(BUILD)
