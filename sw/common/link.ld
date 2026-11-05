/* Bare-metal test programs for the CPU testbenches: RAM at 0x80000000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M }
SECTIONS
{
  .text.init : { *(.text.init) } > RAM
  .text      : { *(.text .text.*) } > RAM
  . = ALIGN(64);
  .tohost    : { *(.tohost) } > RAM
  . = ALIGN(64);
  .data      : { *(.data .data.* .rodata .rodata.* .sdata .sdata.*) } > RAM
  .bss       : { *(.bss .bss.* .sbss .sbss.* COMMON) } > RAM
  _end = .;
}
