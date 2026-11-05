# Debug firmware: drivers (trace, counters, error log, watchdog), crash
# handler, seeded random stress test. Built on the Session 3 runtime in fw/
# (crt0, lib, drivers, pm, arch, platform, monitor), which is not modified.
#
#   make                         build/fw_debug/<platform>-<arch>-<toolchain>/dbgapp.{elf,img,hex,lst}
#   make TOOLCHAIN=gcc|clang     force a toolchain (default: gcc if
#                                riscv64-unknown-elf-gcc exists, else clang + lld)
#   make ARCH=rv32m              in-house core build (build only)
#   make check-toolchains        build with every available toolchain
#
# DBG_BASE: 0x4F004000 for the PicoRV32 integration preview (debug blocks on
# the external port, verif/debug/integ), 0x40020000 otherwise.
PLATFORM  ?= lpsoc
ARCH      ?= picorv32
ROOT      := $(abspath ../..)
FW        := $(ROOT)/fw
HAVE_GCC  := $(shell command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && echo 1)
TOOLCHAIN ?= $(if $(HAVE_GCC),gcc,clang)
BUILD     ?= $(ROOT)/build/fw_debug/$(PLATFORM)-$(ARCH)-$(TOOLCHAIN)
DBG_BASE  ?= $(if $(filter picorv32,$(ARCH)),0x4F004000,0x40020000)
PYTHON    ?= python3

ifeq ($(TOOLCHAIN),gcc)
CC        := riscv64-unknown-elf-gcc
OBJCOPY   := riscv64-unknown-elf-objcopy
OBJDUMP   := riscv64-unknown-elf-objdump
TC_CFLAGS :=
TC_LDFLAGS:= -Wl,--no-warn-rwx-segments
LIBS      := -lgcc
else ifeq ($(TOOLCHAIN),clang)
CC        := clang --target=riscv32-unknown-elf
OBJCOPY   := llvm-objcopy
OBJDUMP   := llvm-objdump
TC_CFLAGS := -Wno-unused-command-line-argument
TC_LDFLAGS:= -fuse-ld=lld
LIBS      := lib/rt64.c
else
$(error TOOLCHAIN must be gcc or clang)
endif

ARCHDEF   := ARCH_$(shell echo $(ARCH) | tr a-z A-Z)
CFLAGS    := -march=rv32im_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -Os -g \
             -ffreestanding -fno-builtin -nostdlib -ffunction-sections -fdata-sections \
             -fno-common -Wall -Wextra -Werror -std=gnu11 $(TC_CFLAGS) \
             -Iinclude -I$(FW)/include -I$(FW)/arch/$(ARCH) -I$(FW)/platform/$(PLATFORM) \
             -D$(ARCHDEF) -DARCH_NAME=\"$(ARCH)\" -DDBG_BASE=$(DBG_BASE)u $(EXTRA_CFLAGS)
LDFLAGS   := -nostdlib -nostartfiles -Wl,--gc-sections $(TC_LDFLAGS)

S3_SRC    := $(addprefix $(FW)/,app/crt0.S lib/printf.c lib/string.c lib/crc32.c lib/trap.c \
             drivers/uart.c drivers/timer.c drivers/intc.c drivers/pmu.c drivers/cache.c \
             pm/pm.c app/monitor.c arch/$(ARCH)/arch.c arch/$(ARCH)/trap_entry.S \
             arch/$(ARCH)/ctx.S arch/$(ARCH)/pm_asm.S platform/$(PLATFORM)/platform.c)
DBG_SRC   := drivers/dbg_trace.c drivers/dbg_evcnt.c drivers/dbg_errlog.c drivers/dbg_wdt.c \
             crash/dbg_crash.c app/dbg_app.c
HDRS      := $(wildcard include/*.h $(FW)/include/*.h)
LDSCRIPT  := $(FW)/platform/$(PLATFORM)/app.ld

.PHONY: all clean check-toolchains list-tests run-test test
all: $(BUILD)/dbgapp.hex

$(BUILD)/dbgapp.elf: $(S3_SRC) $(DBG_SRC) $(HDRS) $(LDSCRIPT)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -T $(LDSCRIPT) -o $@ $(S3_SRC) $(DBG_SRC) $(LIBS)
	$(OBJDUMP) -d $@ > $(BUILD)/dbgapp.lst

$(BUILD)/dbgapp.hex: $(BUILD)/dbgapp.elf
	$(OBJCOPY) -O binary $< $(BUILD)/dbgapp.raw
	$(PYTHON) $(ROOT)/tools/mkimage.py app $(BUILD)/dbgapp.raw $(BUILD)/dbgapp.img $@ \
	    --mem-base 0x20000000 --load-addr 0x20001000

check-toolchains:
	@set -e; for t in gcc clang; do \
	  if [ $$t = gcc ] && [ -z "$(HAVE_GCC)" ]; then echo "SKIP gcc: riscv64-unknown-elf-gcc not found"; continue; fi; \
	  $(MAKE) --no-print-directory TOOLCHAIN=$$t all; echo "BUILD PASS $$t"; \
	done

# regression convention: firmware build checks (runs on the simulator are
# driven by verif/debug/integ)
list-tests:
	@echo build_gcc; echo build_clang; echo build_rv32m
run-test:
	@case "$(TEST)" in \
	  build_gcc)   [ -n "$(HAVE_GCC)" ] || { echo "SKIP: riscv64-unknown-elf-gcc not found"; exit 0; }; \
	               $(MAKE) --no-print-directory TOOLCHAIN=gcc all ;; \
	  build_clang) $(MAKE) --no-print-directory TOOLCHAIN=clang all ;; \
	  build_rv32m) $(MAKE) --no-print-directory ARCH=rv32m all ;; \
	  *) echo "unknown test $(TEST)"; exit 1 ;; \
	esac
test: check-toolchains

clean:
	rm -rf $(ROOT)/build/fw_debug
