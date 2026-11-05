OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 128K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
  } > ROM

  .data : {
    _data_start = .;
    *(.ramtext .ramtext.*)          /* code executed from RAM (copied at cold boot) */
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    _data_end = .;
  } > RAM AT > ROM
  _data_load = LOADADDR(.data);

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM

  /* The last 256 bytes of RAM are never touched by the boot code (no .data,
   * .bss or stack): firmware keeps state across cold reboots there, accessed
   * through the uncached alias. */
  _persist = ORIGIN(RAM) + LENGTH(RAM) - 256;
  _stack_top = _persist;
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
