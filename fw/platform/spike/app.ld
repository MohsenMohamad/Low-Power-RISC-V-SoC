/* Spike: application at 0x8000_0000 (Spike's reset ROM jumps there). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 1M
}

SECTIONS
{
    .image : {
        __image_start = .;
        KEEP(*(.text.start))
        KEEP(*(.header))
        *(.text .text.*)
    } > RAM
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
        __testtab_start = .;
        KEEP(*(.testtab))
        __testtab_end = .;
    } > RAM
    .tohost : ALIGN(64) { KEEP(*(.tohost)) } > RAM
    .data : {
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
        __image_end = .;
    } > RAM
    __image_size = __image_end - __image_start;
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
