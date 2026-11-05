# Firmware build: GCC 13.2 / binutils 2.42 (riscv64-unknown-elf), doc/SPEC.md:
# -march=rv32im_zicsr_zifencei -mabi=ilp32, no compressed instructions.
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
PYTHON  ?= python3
BUILD   ?= ../build/fw

ARCH    := -march=rv32im_zicsr_zifencei -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -g -ffreestanding -fno-builtin -nostdlib -mno-relax \
           -msmall-data-limit=0 -Wall -Wextra -Werror -Iinclude
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -Wl,-T,link.ld -Wl,--no-relax -Wl,--no-warn-rwx-segments -static -lgcc

PROGS   := pm_test boot_test

all: $(PROGS:%=$(BUILD)/%.hex)

$(BUILD)/%.elf: crt0.S %.c include/soc.h link.ld | $(BUILD)
	$(CC) $(CFLAGS) -o $@ crt0.S $*.c $(LDFLAGS)

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.data $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) ../scripts/bin2hex.py $< $@ 4096
	$(OBJDUMP) -d $(BUILD)/$*.elf > $(BUILD)/$*.dis
	@if $(OBJDUMP) -d $(BUILD)/$*.elf | grep -qE '^\s+[0-9a-f]+:\s+[0-9a-f]{4}\s+c\.'; then \
	  echo "error: compressed instruction in $*"; exit 1; fi

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin
