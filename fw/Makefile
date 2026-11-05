# Bare-metal firmware: one tree for every platform (doc/BOOT_ABI.md, doc/SPEC.md).
# GCC 13.2 / binutils 2.42 (riscv64-unknown-elf), -march=rv32im_zicsr_zifencei
# -mabi=ilp32, no compressed instructions (the build fails if one appears).
#
#   make                  PLATFORM=lpsoc: boot ROM + application images
#   make PLATFORM=spike   validation suite for the Spike ISA simulator
#   make all-platforms    both
#
# lpsoc outputs in $(BUILD): rom.hex (ROM image, 16 KB), and for each
# application <app>.img / <app>.hex (RAM image at 0x1000_1000 with the image
# header, loaded by the host/testbench), <app>.elf, <app>.lst:
#   suite      validation suite + UART monitor (fw/app/main.c)
#   pm_test    SoC power-management integration test (stage 1)
#   boot_test  boot ROM / resume ABI test (stage 1)
#   neg_fail   prints a FAIL verdict (negative test of the testbench)
# spike outputs: suite.elf

PLATFORM ?= lpsoc
ROOT     := $(abspath ..)
BUILD    ?= $(ROOT)/build/fw/$(PLATFORM)
ARCH     := rv32m

CROSS    ?= riscv64-unknown-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size
PYTHON   ?= python3

CFLAGS   := -march=rv32im_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -Os -g \
            -ffreestanding -fno-builtin -nostdlib -ffunction-sections -fdata-sections \
            -fno-common -Wall -Wextra -Werror -std=gnu11 \
            -Iinclude -Iarch/$(ARCH) -Iplatform/$(PLATFORM) \
            -DARCH_NAME=\"$(ARCH)\" $(EXTRA_CFLAGS)
LDFLAGS  := -nostdlib -nostartfiles -Wl,--gc-sections -Wl,--no-warn-rwx-segments

COMMON   := lib/printf.c lib/string.c lib/crc32.c lib/trap.c \
            drivers/uart.c drivers/timer.c drivers/wtimer.c drivers/intc.c drivers/pmu.c \
            drivers/cache.c pm/pm.c app/monitor.c \
            arch/$(ARCH)/arch.c arch/$(ARCH)/trap_entry.S arch/$(ARCH)/ctx.S arch/$(ARCH)/pm_asm.S \
            platform/$(PLATFORM)/platform.c
ROM_SRC  := bootrom/start.S bootrom/rom_main.c $(COMMON)
APP_SRC   = app/crt0.S $(COMMON) $(APP_SRC_$(1))
APP_SRC_suite     := app/main.c app/suite.c $(wildcard tests/*.c) tests/regs_asm.S
APP_SRC_pm_test   := app/pm_test.c
APP_SRC_boot_test := app/boot_test.c
APP_SRC_neg_fail  := app/neg_fail.c
HDRS     := $(wildcard include/*.h arch/$(ARCH)/*.h platform/$(PLATFORM)/*.h) Makefile

ifeq ($(PLATFORM),lpsoc)
APPS     := suite pm_test boot_test neg_fail
TARGETS  := $(BUILD)/rom.hex $(APPS:%=$(BUILD)/%.hex)
else
APPS     := suite
TARGETS  := $(BUILD)/suite.elf
endif

# Fail on any compressed instruction (doc/SPEC.md: none allowed).
define no_rvc
	@if $(OBJDUMP) -d $(1) | grep -qE '^\s+[0-9a-f]+:\s+[0-9a-f]{4}\s+c\.'; then \
	  echo "error: compressed instruction in $(1)"; exit 1; fi
endef

.PHONY: all all-platforms clean
all: $(TARGETS)

all-platforms:
	$(MAKE) PLATFORM=lpsoc
	$(MAKE) PLATFORM=spike

$(BUILD)/rom.elf: $(ROM_SRC) $(HDRS) platform/lpsoc/rom.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -T platform/lpsoc/rom.ld -o $@ $(ROM_SRC) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/rom.lst
	$(call no_rvc,$@)

$(BUILD)/rom.hex: $(BUILD)/rom.elf $(ROOT)/tools/mkimage.py
	$(OBJCOPY) -O binary $< $(BUILD)/rom.bin
	$(PYTHON) $(ROOT)/tools/mkimage.py rom $(BUILD)/rom.bin $@ --size 0x4000

.SECONDEXPANSION:
$(BUILD)/%.elf: $$(call APP_SRC,$$*) $(HDRS) platform/$(PLATFORM)/app.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -T platform/$(PLATFORM)/app.ld -o $@ $(call APP_SRC,$*) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/$*.lst
	$(call no_rvc,$@)
	$(SIZE) $@

$(BUILD)/%.hex: $(BUILD)/%.elf $(ROOT)/tools/mkimage.py
	$(OBJCOPY) -O binary $< $(BUILD)/$*.raw
	$(PYTHON) $(ROOT)/tools/mkimage.py app $(BUILD)/$*.raw $(BUILD)/$*.img $@ \
	    --mem-base 0x10000000 --load-addr 0x10001000

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(ROOT)/build/fw

.PRECIOUS: $(BUILD)/%.elf
