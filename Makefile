# Top level.
#   make fw     firmware for all configurations
#   make sim    Verilator model of the PicoRV32 bring-up SoC
#   make lint   Verilator lint of the bring-up SoC RTL
#   make test   build and run everything (tools/run_tests.py), summary in
#               build/test/summary.txt
.PHONY: all fw sim lint test clean

all: fw sim

fw:
	$(MAKE) -C fw all-configs

sim:
	$(MAKE) -C platform/picorv32 sim

lint:
	$(MAKE) -C platform/picorv32 lint

test:
	python3 tools/run_tests.py

clean:
	rm -rf build
