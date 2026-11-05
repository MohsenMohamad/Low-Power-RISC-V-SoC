# Bare-metal firmware: boot ROM + application (validation suite, monitor).
#
#   make PLATFORM=lpsoc ARCH=picorv32   PicoRV32 bring-up SoC (simulated)
#   make PLATFORM=spike ARCH=rv32m      Spike ISA simulator
#   make PLATFORM=lpsoc ARCH=rv32m      in-house core (build only)
#   make all-configs                    all three
#
# Outputs in $(BUILD): rom.elf rom.hex (lpsoc), app.elf app.img app.hex, *.lst

PLATFORM ?= lpsoc
ARCH     ?= picorv32
ROOT     := $(abspath ..)
BUILD    ?= $(ROOT)/build/fw/$(PLATFORM)-$(ARCH)

CROSS    ?= riscv64-unknown-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size
PYTHON   ?= python3

ARCHDEF  := ARCH_$(shell echo $(ARCH) | tr a-z A-Z)
CFLAGS   := -march=rv32im_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -Os -g \
            -ffreestanding -fno-builtin -nostdlib -ffunction-sections -fdata-sections \
            -fno-common -Wall -Wextra -Werror -std=gnu11 \
            -Iinclude -Iarch/$(ARCH) -Iplatform/$(PLATFORM) \
            -D$(ARCHDEF) -DARCH_NAME=\"$(ARCH)\" $(EXTRA_CFLAGS)
LDFLAGS  := -nostdlib -nostartfiles -Wl,--gc-sections -Wl,--no-warn-rwx-segments

COMMON   := lib/printf.c lib/string.c lib/crc32.c lib/trap.c \
            drivers/uart.c drivers/timer.c drivers/intc.c drivers/pmu.c drivers/cache.c \
            pm/pm.c app/monitor.c \
            arch/$(ARCH)/arch.c arch/$(ARCH)/trap_entry.S arch/$(ARCH)/ctx.S arch/$(ARCH)/pm_asm.S \
            platform/$(PLATFORM)/platform.c
ROM_SRC  := bootrom/start.S bootrom/rom_main.c $(COMMON)
APP_SRC  := app/crt0.S app/main.c app/suite.c $(wildcard tests/*.c) tests/regs_asm.S $(COMMON)
HDRS     := $(wildcard include/*.h arch/$(ARCH)/*.h platform/$(PLATFORM)/*.h)

TARGETS  := $(BUILD)/app.elf
ifeq ($(PLATFORM),lpsoc)
TARGETS  += $(BUILD)/rom.hex $(BUILD)/app.hex
endif

.PHONY: all all-configs clean
all: $(TARGETS)

all-configs:
	$(MAKE) PLATFORM=lpsoc ARCH=picorv32
	$(MAKE) PLATFORM=spike ARCH=rv32m
	$(MAKE) PLATFORM=lpsoc ARCH=rv32m

$(BUILD)/rom.elf: $(ROM_SRC) $(HDRS) platform/lpsoc/rom.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -T platform/lpsoc/rom.ld -o $@ $(ROM_SRC) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/rom.lst

$(BUILD)/app.elf: $(APP_SRC) $(HDRS) platform/$(PLATFORM)/app.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -T platform/$(PLATFORM)/app.ld -o $@ $(APP_SRC) -lgcc
	$(OBJDUMP) -d $@ > $(BUILD)/app.lst
	$(SIZE) $@

$(BUILD)/rom.hex: $(BUILD)/rom.elf
	$(OBJCOPY) -O binary $< $(BUILD)/rom.bin
	$(PYTHON) $(ROOT)/tools/mkimage.py rom $(BUILD)/rom.bin $@ --size 0x4000

$(BUILD)/app.hex: $(BUILD)/app.elf
	$(OBJCOPY) -O binary $< $(BUILD)/app.raw
	$(PYTHON) $(ROOT)/tools/mkimage.py app $(BUILD)/app.raw $(BUILD)/app.img $@ \
	    --mem-base 0x20000000 --load-addr 0x20001000

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(ROOT)/build/fw
