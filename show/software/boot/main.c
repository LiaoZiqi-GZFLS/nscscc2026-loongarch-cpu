/*
 * main.c - NSCSCC2026 mini bootloader (LA32R + chiplab nscscc-team SoC)
 *
 * Flow:
 *   1. print boot info (version, memory map, UART settings)
 *   2. locate next-stage image at IMAGE_PHYS (preloaded via JTAG-AXI)
 *      - ELF32: parse program headers, copy PT_LOAD segments to their
 *        physical load address (kseg addresses folded by & 0x1FFFFFFF)
 *      - raw binary (BOOT_RAW_BINARY): jump to RAW_ENTRY, no copy
 *   3. build the Linux fw_arg block (argc/argv/BPI + "MEM" list)
 *   4. boot_jump(entry, argc, argv, bpi)
 */
#include "boot.h"

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

extern void boot_jump(u32 entry, u32 argc, u32 argv, u32 bpi);

/* ------------------------------------------------------------------ */
/* Unaligned-safe memory access (LA32R UAL is optional, do byte I/O)   */
/* ------------------------------------------------------------------ */
static void wr32(u32 addr, u32 val)
{
    volatile u8 *p = (volatile u8 *)addr;
    p[0] = val & 0xff;
    p[1] = (val >> 8) & 0xff;
    p[2] = (val >> 16) & 0xff;
    p[3] = (val >> 24) & 0xff;
}

static u32 rd32(u32 addr)
{
    volatile u8 *p = (volatile u8 *)addr;
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static u16 rd16(u32 addr)
{
    volatile u8 *p = (volatile u8 *)addr;
    return (u16)((u32)p[0] | ((u32)p[1] << 8));
}

static void mem_fill(u32 dst, u8 val, u32 n)
{
    volatile u8 *d = (volatile u8 *)dst;
    while (n--)
        *d++ = val;
}

static void mem_copy(u32 dst, u32 src, u32 n)
{
    volatile u8 *d = (volatile u8 *)dst;
    volatile u8 *s = (volatile u8 *)src;
    while (n--)
        *d++ = *s++;
}

static void str_copy(u32 dst, const char *s)
{
    volatile u8 *d = (volatile u8 *)dst;
    while ((*d++ = (u8)*s++) != 0)
        ;
}

/* ------------------------------------------------------------------ */
/* UART console                                                        */
/* ------------------------------------------------------------------ */
#define UART_REG(x)     ((volatile u8 *)(UART_BASE + (x)))

static void putc(char c)
{
    while ((UART_REG(5)[0] & 0x20) == 0)    /* LSR.THRE */
        ;
    UART_REG(0)[0] = (u8)c;
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
        /* multiply-free division by 10 via reciprocal shift is */
        /* overkill here; gcc emits mul.w-based sequence anyway */
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i)
        putc(buf[--i]);
}

/* ------------------------------------------------------------------ */
/* ELF32 loader (~30 lines)                                            */
/* ------------------------------------------------------------------ */
#define EM_LOONGARCH    258

static int __attribute__((unused)) elf_load(u32 img, u32 *entry)
{
    u32 phoff, phentsize, phnum, i;

    if (rd32(img) != 0x464c457f)            /* \x7f 'E' 'L' 'F' */
        return -1;
    if (*(volatile u8 *)(img + 4) != 1) {   /* EI_CLASS == 32   */
        puts("ELF: not 32-bit\n");
        return -1;
    }
    if (rd16(img + 18) != EM_LOONGARCH)     /* e_machine        */
        puts("ELF: warning: e_machine is not LoongArch\n");

    *entry    = rd32(img + 24);             /* e_entry   */
    phoff     = rd32(img + 28);             /* e_phoff   */
    phentsize = rd16(img + 42);             /* e_phentsize */
    phnum     = rd16(img + 44);             /* e_phnum   */

    for (i = 0; i < phnum; i++) {
        u32 ph = img + phoff + i * phentsize;
        u32 type, vaddr, paddr, filesz, memsz, off, dst;
        type   = rd32(ph + 0);
        if (type != 1)                      /* PT_LOAD */
            continue;
        off    = rd32(ph + 4);
        vaddr  = rd32(ph + 8);
        paddr  = rd32(ph + 12);
        filesz = rd32(ph + 16);
        memsz  = rd32(ph + 20);
        dst    = paddr ? paddr : vaddr;
        if (dst >= 0x80000000)              /* fold kseg -> phys */
            dst &= 0x1fffffff;
        puts("  LOAD ");
        puthex(dst);
        puts(" filesz=");
        puthex(filesz);
        puts(" memsz=");
        puthex(memsz);
        puts("\n");
        if (dst < DDR_BASE || dst + memsz > DDR_END)
            puts("  WARNING: segment outside DDR window\n");
        mem_copy(dst, img + off, filesz);
        if (memsz > filesz)
            mem_fill(dst + filesz, 0, memsz - filesz);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* fw_arg block for la32r-Linux 5.14 (old-world protocol)              */
/* ------------------------------------------------------------------ */
#define ADDR_TYPE_SYSRAM    1
#define ADDR_TYPE_RESERVED  2

static void build_fw_arg(void)
{
    u32 a   = FWARG_PHYS;
    u32 mem = a + OFF_MEMNODE;
    u32 len = 19 + 2 * 12;          /* header(19) + 2 entries         */
    u32 sum, i;

    mem_fill(a, 0, 0x400);          /* scrub argv/strings/BPI/node    */

    /* argv[] = { "boot", cmdline, NULL, NULL }                        */
    wr32(a + OFF_ARGV + 0, KVIRT(a + OFF_ARGV0_STR));
    wr32(a + OFF_ARGV + 4, KVIRT(a + OFF_CMDLINE));
    str_copy(a + OFF_ARGV0_STR, "boot");
    str_copy(a + OFF_CMDLINE, BOOT_CMDLINE);

    /* struct bootparamsinterface                                      */
    mem_copy(a + OFF_BPI, (u32)"BPI01000", 8);    /* signature        */
    wr32(a + OFF_BPI + 8,  0);                    /* systemtable      */
    wr32(a + OFF_BPI + 12, KVIRT(mem));           /* extlist          */
    wr32(a + OFF_BPI + 16, 0);                    /* flags lo         */
    wr32(a + OFF_BPI + 20, 0);                    /* flags hi         */

    /* "MEM" extension-list node                                       */
    mem_copy(mem, (u32)"MEM", 3);                 /* signature (8B)   */
    wr32(mem + 8, len);                           /* hdr.length       */
    /* mem[12] = revision = 0, mem[13] = checksum (below)              */
    wr32(mem + 14, 0);                            /* hdr.next = NULL  */
    *(volatile u8 *)(mem + 18) = 2;               /* map_count        */
    wr32(mem + 19 + 0,  ADDR_TYPE_SYSRAM);        /* map[0]           */
    wr32(mem + 19 + 4,  MEM_BASE);
    wr32(mem + 19 + 8,  MEM_SIZE);
    wr32(mem + 19 + 12, ADDR_TYPE_RESERVED);      /* map[1]: fw_arg   */
    wr32(mem + 19 + 16, FWARG_PHYS);
    wr32(mem + 19 + 20, 0x10000);

    /* checksum: byte-sum over hdr.length bytes must come out zero     */
    sum = 0;
    for (i = 0; i < len; i++)
        sum += *(volatile u8 *)(mem + i);
    *(volatile u8 *)(mem + 13) = (u8)(0 - sum);
}

/* ------------------------------------------------------------------ */
int main(void)
{
    u32 entry = 0;
    int rc;

    puts("DDR      : ");
    puthex(DDR_BASE);
    puts(" size ");
    putdec(DDR_SIZE / 1048576);
    puts(" MB\n");
    puts("UART     : ");
    puthex(UART_BASE);
    puts(" pclk ");
    putdec(UART_PCLK / 1000000);
    puts(" MHz, ");
    putdec(UART_BAUD);
    puts(" 8N1 (div=");
    putdec(UART_DIV);
    puts(")\n");
    puts("Image    : probe ");
    puthex(IMAGE_PHYS);
    puts("\n");

#ifdef BOOT_RAW_BINARY
    entry = RAW_ENTRY;
    puts("Mode     : raw binary, entry ");
    puthex(entry);
    puts("\n");
    rc = 0;
#else
    rc = elf_load(IMAGE_PHYS, &entry);
    if (rc != 0)
        puts("Image    : no valid ELF32 found (build with -DBOOT_RAW_BINARY for bare bin)\n");
#endif

    if (rc != 0 || entry == 0) {
        puts("BOOT FAILED: halt\n");
        for (;;)
            ;
    }

    build_fw_arg();
    puts("fw_arg   : argc=2 argv=");
    puthex(KVIRT(FWARG_PHYS + OFF_ARGV));
    puts(" bpi=");
    puthex(KVIRT(FWARG_PHYS + OFF_BPI));
    puts("\n");
    puts("cmdline  : " BOOT_CMDLINE "\n");
    puts("MEM list : SYSRAM ");
    puthex(MEM_BASE);
    puts(" size ");
    puthex(MEM_SIZE);
    puts("\n");
    puts("Jumping to entry ");
    puthex(entry);
    puts(" ...\n\n");

    boot_jump(entry, 2, KVIRT(FWARG_PHYS + OFF_ARGV),
              KVIRT(FWARG_PHYS + OFF_BPI));

    /* not reached */
    for (;;)
        ;
    return 0;
}
