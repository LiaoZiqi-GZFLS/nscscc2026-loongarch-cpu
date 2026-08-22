/*
 * demo_payload.ld - link script for the bootloader showcase payload.
 *
 * Linked at VA 0xbc200000.  The bootloader's ELF loader folds kseg
 * addresses with "addr & 0x1fffffff", so this lands at phys 0x1c200000
 * (bit28 must be set for the fold to reach the 0x1c000000 DDR window):
 * clear of the bootloader (0x1c000000), the staging area (0x1c400000)
 * and the fw_arg block (0x1cff0000).  The linked VA stays inside the
 * DMW0 window the bootloader derives from the entry address (VSEG=5 ->
 * 0xa0000000-0xbfffffff -> phys 0x00000000-0x1fffffff).
 */
OUTPUT_FORMAT("elf32-loongarch")
OUTPUT_ARCH(loongarch)
ENTRY(_start)

SECTIONS
{
    . = 0xbc200000;
    .text   : { *(.text*) }
    .rodata : { *(.rodata*) }
    . = ALIGN(4);
    .data   : { *(.data*) }
    . = ALIGN(4);
    __bss_start = .;
    .bss    : { *(.bss*) }
    _end = .;
}
