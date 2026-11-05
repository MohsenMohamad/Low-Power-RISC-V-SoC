/* Application image in RAM from 0x1000_1000; stack at the top of RAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x10001000, LENGTH = 0x1F000
}

SECTIONS
{
    .image : {
        __image_start = .;
        KEEP(*(.header))
        KEEP(*(.text.start))
        *(.text .text.*)
    } > RAM
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
        __testtab_start = .;
        KEEP(*(.testtab))
        __testtab_end = .;
    } > RAM
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
    ASSERT(__bss_end <= __stack_top - 0x2000, "less than 8 KB left for the stack")
}
