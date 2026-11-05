# Firmware build (clang + lld; no GNU RISC-V toolchain required)
RV_CC   ?= clang
OBJCOPY ?= llvm-objcopy
OBJDUMP ?= llvm-objdump
PYTHON  ?= python3
BUILD   ?= ../build/fw

ARCH    := --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -g -ffreestanding -fno-builtin -nostdlib -mno-relax \
           -Wall -Wextra -Werror -Iinclude
LDFLAGS := $(ARCH) -nostdlib -fuse-ld=lld -Wl,-T,link.ld -Wl,--no-relax -static

PROGS   := pm_test

all: $(PROGS:%=$(BUILD)/%.hex)

$(BUILD)/%.elf: crt0.S %.c include/soc.h link.ld | $(BUILD)
	$(RV_CC) $(CFLAGS) $(LDFLAGS) -o $@ crt0.S $*.c

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) ../scripts/bin2hex.py $< $@ 4096
	$(OBJDUMP) -d $(BUILD)/$*.elf > $(BUILD)/$*.dis

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin
