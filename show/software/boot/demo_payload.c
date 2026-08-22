/*
 * demo_payload.c - bootloader showcase payload for the NSCSCC2026 finals demo
 *
 * Loaded by the mini bootloader (sw/boot) from the staging area 0x1c400000 to
 * its linked physical address 0x1c200000 (VA 0xbc200000 through the window the
 * bootloader configured), then entered via boot_jump() with:
 *   DMW0 = 0xa0000001  (VA 0xa0000000-0xbfffffff -> PA 0x00000000-0x1fffffff)
 *   DMW1 = 0x00000001  (identity window, reaches UART/CONFREG at 0x1fe0/0x1faf)
 *   CRMD = 0x10        (PLV0, PG=1)
 *   a0 = argc = 2, a1 = argv, a2 = bpi   (all KVIRT pointers into the fw_arg
 *                                         block at the top of DDR, 0x1cff0000)
 *
 * The link address 0xbc200000 is chosen so the ELF loader's destination
 * (kseg-folded 0x1c200000, bit28 must be set for the fold) stays clear of the
 * bootloader itself (0x1c000000), the staging area (0x1c400000) and the
 * fw_arg block.  Loading ucore directly
 * through the bootloader is NOT safe: ucore links at 0xbc000000 which folds
 * to 0x1c000000 and would overwrite the running bootloader (its DA-mode code
 * fetches are uncached); see sw/ucore/demo/DEMO.md.
 *
 * The payload verifies the complete bootloader handoff protocol end to end:
 * it reads argv/cmdline, the BPI signature and the MEM node (including its
 * checksum), prints everything to UART, shows "B007" on the 7-segment
 * display and then halts.  It deliberately does NOT touch CSRs or caches -
 * it runs entirely inside the windows the bootloader already configured.
 */
#include "boot.h"

typedef unsigned int u32;
typedef unsigned char u8;

/* saved by demo_start.S */
extern u32 saved_a0, saved_a1, saved_a2;

#define SEG_BASE        0x1faff050      /* CONFREG 7-segment register */

static void putc(char c)
{
    while ((*(volatile u8 *)(UART_BASE + 5) & 0x20) == 0)   /* LSR.THRE */
        ;
    *(volatile u8 *)(UART_BASE + 0) = (u8)c;
    if (c == '\n')
        putc('\r');
}

static void puts(const char *s)
{
    while (*s)
        putc(*s++);
}

static void puthex(u32 v)
{
    int i;
    puts("0x");
    for (i = 7; i >= 0; i--) {
        u32 nib = (v >> (i * 4)) & 0xf;
        putc((char)(nib < 10 ? '0' + nib : 'a' + nib - 10));
    }
}

static void putdec(u32 v)
{
    char buf[10];
    int i = 0;
    if (v == 0) {
        putc('0');
        return;
    }
    while (v) {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i)
        putc(buf[--i]);
}

static u32 rd32(u32 addr)
{
    volatile u8 *p = (volatile u8 *)addr;
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static const char *mem_type_name(u32 t)
{
    switch (t) {
    case 1:  return "SYSRAM";
    case 2:  return "RESERVED";
    default: return "(unknown)";
    }
}

int main(void)
{
    u32 argc = saved_a0, argv_addr = saved_a1, bpi_addr = saved_a2;
    u32 mem, len, next, count, cs, i;

    *(volatile u32 *)SEG_BASE = 0xb0070000;     /* "B007" on the 7-seg display */

    puts("\n==============================\n");
    puts(" NSCSCC2026 demo payload v1.0\n");
    puts("==============================\n");
    puts("linked  : 0xbc200000 (phys 0x1c200000)\n");
    puts("loaded  : by NSCSCC2026 mini bootloader from staging 0x1c400000\n\n");

    puts("fw_arg handoff:\n");
    puts("  argc = ");
    putdec(argc);
    puts("\n");
    for (i = 0; i < argc; i++) {
        u32 p = rd32(argv_addr + 4 * i);
        puts("  argv[");
        putdec(i);
        puts("] = ");
        puthex(p);
        if (p) {
            puts(" -> \"");
            puts((const char *)p);
            puts("\"\n");
        } else {
            puts("\n");
        }
    }

    puts("  bpi  = ");
    puthex(bpi_addr);
    puts(" sig=\"");
    for (i = 0; i < 8; i++)
        putc(*(volatile u8 *)(bpi_addr + i));
    puts("\"\n");

    /* walk the BPI extension-list to the MEM node */
    mem = rd32(bpi_addr + 12);
    puts("  MEM node: sig=\"");
    for (i = 0; i < 3; i++)
        putc(*(volatile u8 *)(mem + i));
    puts("\" len=");
    len = rd32(mem + 8);
    putdec(len);
    puts(" rev=");
    putdec(*(volatile u8 *)(mem + 12));
    puts(" next=");
    next = rd32(mem + 14);
    puthex(next);
    cs = 0;
    for (i = 0; i < len; i++)
        cs = (u8)(cs + *(volatile u8 *)(mem + i));
    puts(" checksum=");
    putdec(cs);
    puts(cs == 0 ? " OK\n" : " FAIL\n");

    count = *(volatile u8 *)(mem + 18);
    puts("  memory map (");
    putdec(count);
    puts(" entries):\n");
    for (i = 0; i < count; i++) {
        u32 *e = (u32 *)(mem + 19 + 12 * i);
        puts("    map[");
        putdec(i);
        puts("] type=");
        puts(mem_type_name(rd32((u32)&e[0])));
        puts(" start=");
        puthex(rd32((u32)&e[1]));
        puts(" size=");
        puthex(rd32((u32)&e[2]));
        puts("\n");
    }

    puts("\nPAYLOAD_OK\n");
    for (;;)
        ;
    return 0;
}
