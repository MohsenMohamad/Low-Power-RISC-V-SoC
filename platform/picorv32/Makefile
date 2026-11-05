# PicoRV32-based firmware bring-up platform (Verilator).
ROOT     := $(abspath ../..)
BUILD    ?= $(ROOT)/build/picorv32
RTL      := $(ROOT)/rtl/tech/tc_sync.sv $(ROOT)/rtl/tech/tc_rst_sync.sv \
            $(ROOT)/rtl/tech/tc_clk_gate.sv $(ROOT)/rtl/tech/tc_clk_mux_gf.sv \
            $(ROOT)/rtl/tech/tc_iso.sv $(ROOT)/rtl/tech/tc_pwr_switch.sv \
            $(ROOT)/rtl/tech/tc_sram.sv $(ROOT)/rtl/tech/tc_vreg.sv \
            $(ROOT)/third_party/picorv32/picorv32.v \
            rtl/pico_cache.sv rtl/bus_cdc.sv rtl/pico_pd_cpu.sv \
            rtl/aon_uart.sv rtl/aon_timer.sv rtl/aon_intc.sv rtl/aon_pmu.sv \
            rtl/pico_soc.sv
TB       := tb/tb_top.sv
SIM      := $(BUILD)/obj/Vtb_top

VFLAGS   := --timing --timescale 1ns/1ps -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
            --x-assign unique --x-initial unique -O2 \
            -Wno-fatal

.PHONY: sim lint clean
sim: $(SIM)

$(SIM): $(RTL) $(TB) lint.vlt
	verilator --binary $(VFLAGS) --top-module tb_top -Mdir $(BUILD)/obj \
	    lint.vlt $(RTL) $(TB) -j 4 > $(BUILD)/verilator.log 2>&1 || (cat $(BUILD)/verilator.log; exit 1)
	@grep -c '%Warning' $(BUILD)/verilator.log | xargs -I{} echo "verilator warnings: {}"

lint:
	@mkdir -p $(BUILD)
	verilator --lint-only -Wall -Wno-DECLFILENAME --timing --timescale 1ns/1ps --top-module pico_soc lint.vlt $(RTL)

clean:
	rm -rf $(BUILD)
