/* Boot ROM: code in the 16 KB ROM, .data/.bss/stack in RAM 0x400-0xFFF. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM    (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    ROMRAM (rw)  : ORIGIN = 0x20000400, LENGTH = 0xC00
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ROM
    .data : {
        __data_start = .;
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > ROMRAM AT > ROM
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ROMRAM
    __rom_end = LOADADDR(.data) + SIZEOF(.data);
    ASSERT(__bss_end <= 0x20000E00, "boot ROM .bss leaves less than 512 B of stack")
}
