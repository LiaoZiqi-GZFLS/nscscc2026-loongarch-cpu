/*
 * boot.h - shared constants for the NSCSCC2026 mini bootloader
 *
 * Target platform : chiplab (nscscc2026 branch), nscscc-team minimal SoC
 *   DDR3      : 0x1C000000, 16MB window (AXI crossbar M01, ADDR_WIDTH=24)
 *   UART16550 : 0x1FE001E0  (AXI crossbar M02 +0x1E0, Loongson URT core)
 *   CONFREG   : 0x1FAF0000  (M00, timer at +0xE000)
 *   CPU reset : fetch from 0x1C000000 in DA mode (direct physical addressing)
 *
 * The CPU comes out of reset with CRMD.DA=1, so all addresses below are
 * physical addresses until boot_jump() enables PG.
 */
#ifndef _BOOT_H_
#define _BOOT_H_

/* ------------------------------------------------------------------ */
/* Memory map                                                          */
/* ------------------------------------------------------------------ */
#define DDR_BASE        0x1C000000
#define DDR_SIZE        0x01000000      /* 16 MB (chiplab nscscc-team window) */
#define DDR_END         (DDR_BASE + DDR_SIZE)

/* fw_arg block: top 64KB of DDR, stack sits right below it */
#define FWARG_PHYS      (DDR_END - 0x10000)     /* 0x1CFF0000 */
#define STACK_TOP       FWARG_PHYS

/* Next-stage image is preloaded here by JTAG-AXI (see README) */
#define IMAGE_PHYS      0x1C400000

/* Memory description advertised to the kernel in the BPI "MEM" list */
#define MEM_BASE        DDR_BASE
#define MEM_SIZE        DDR_SIZE

/* ------------------------------------------------------------------ */
/* UART (16550 compatible, Loongson URT)                               */
/*                                                                     */
/* URT baud generator: baud = PCLK / (16 * dl), dl is a 24-bit         */
/* fractional divider {DL3[7:0], DLM, DLL} (see IP/APB_DEV/URT/        */
/* uart_regs.v: dlc <= dl - 1 + M_toggle, first-order DSM on DL3).     */
/* PCLK = sys_clk = 100 MHz on the nscscc-team SoC (clk_pll clk_out2,  */
/* fixed by the contest rules; only cpu_clk is configurable).          */
/*                                                                     */
/* 100 MHz / 115200 -> dl = 54.2539 -> DLL=54(0x36), DL3=64(0x40)      */
/* => 115212 baud, -0.06% error.  If your PLL/UART clock differs,      */
/* rebuild with -DUART_PCLK=<hz>; see README "baud calibration".       */
/* ------------------------------------------------------------------ */
#define UART_BASE       0x1FE001E0
#ifndef UART_PCLK
#define UART_PCLK       100000000
#endif
#ifndef UART_BAUD
#define UART_BAUD       115200
#endif
#define UART_DIV        ((UART_PCLK + 8 * UART_BAUD) / (16 * UART_BAUD))
/* fractional part * 256, kept in 32-bit range for the assembler */
#define UART_DIV_FRAC   (((UART_PCLK % (16 * UART_BAUD)) * 256) / \
                          (16 * UART_BAUD))

/* ------------------------------------------------------------------ */
/* Linux boot protocol (la32r-Linux 5.14, old-world fw_arg)            */
/*                                                                     */
/*   a0 = argc, a1 = argv[], a2 = struct bootparamsinterface *         */
/* argv[] = { "boot", "<cmdline>", NULL }                              */
/* a2 -> { u64 "BPI01000"; u32 systemtable; u32 extlist; u64 flags }   */
/* extlist -> "MEM" node:                                              */
/*   hdr { u64 "MEM\0.."; u32 length; u8 rev; u8 cksum; u32 next=0 }   */
/*   u8 map_count; map[] { u32 type,start,size } (packed)              */
/* checksum: byte-sum over hdr.length bytes of the node must be 0.     */
/* (arch/loongarch/kernel/cmdline.c, loongson32/env.c, mem.c,          */
/*  include/asm/mach-loongson32/boot_param.h)                          */
/*                                                                     */
/* Pointers handed to the kernel are virtual: 0xA0000000 | phys,       */
/* reachable through the kernel's DMW0 window (0xA****** -> PA 0*).    */
/* ------------------------------------------------------------------ */
#define KVIRT(x)        (0xA0000000 | (x))

#ifndef BOOT_CMDLINE
#define BOOT_CMDLINE    "console=ttyS0,115200"
#endif

#define BOOT_VERSION    "0.1"

/* fw_arg block layout (offsets from FWARG_PHYS) */
#define OFF_ARGV        0x000           /* u32 argv[4]                  */
#define OFF_ARGV0_STR   0x020           /* "boot"                       */
#define OFF_CMDLINE     0x040           /* cmdline string, max 240B     */
#define OFF_BPI         0x140           /* bootparamsinterface, 24B     */
#define OFF_MEMNODE     0x160           /* MEM link-list node           */

/* Raw-binary mode: define BOOT_RAW_BINARY to skip ELF parsing and jump */
/* straight to RAW_ENTRY with the image already in place.               */
#define RAW_ENTRY       IMAGE_PHYS

#endif /* _BOOT_H_ */
