/*
 * linker.ld - NSCSCC2026 mini bootloader
 * Boot image is loaded/fetched at the chiplab DDR base 0x1C000000.
 */
OUTPUT_ARCH(loongarch)
ENTRY(_start)

SECTIONS
{
    . = 0x1C000000;

    .text : {
        *(.text.entry)      /* _start must land exactly at 0x1C000000 */
        *(.text)
        *(.text.*)
    }

    . = ALIGN(8);
    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.srodata*)
    }

    . = ALIGN(8);
    .data : {
        *(.data)
        *(.data.*)
        *(.sdata*)
    }

    . = ALIGN(8);
    __bss_start = .;
    .bss : {
        *(.sbss*)
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }
    . = ALIGN(8);
    _end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment*)
        *(.eh_frame*)
    }
}
