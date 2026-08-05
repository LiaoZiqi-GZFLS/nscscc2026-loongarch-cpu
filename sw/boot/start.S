/*
 * start.S - reset entry of the NSCSCC2026 mini bootloader
 *
 * Linked at 0x1C000000 (== CPU reset fetch address on chiplab).
 * Runs in DA mode (direct physical addressing) the whole time; PG is
 * only enabled inside boot_jump() right before entering the next stage,
 * mirroring the proven chiplab linux example start.S flow:
 *   DMW0 = (entry & 0xE0000000) | 0x1   (uncached window -> PA 0x00000000)
 *   DMW1 = 0x00000001                   (identity window, uncached)
 *   CRMD = 0x10                         (PLV=0, IE=0, DA=0, PG=1)
 */
#include "boot.h"

    .text
    .section .text.entry
    .globl _start
_start:
    /* 1. Kill interrupts / exceptions plumbing, stay in DA mode, PLV0  */
    li.w    $r12, 0x8           /* CRMD: PLV=0, IE=0, DA=1, PG=0       */
    csrwr   $r12, 0x0           /* CSR_CRMD                            */
    csrwr   $r0,  0x4           /* CSR_ECFG:  no interrupt sources     */
    csrwr   $r0,  0x41          /* CSR_TCFG:  timer off                */
    csrwr   $r0,  0x44          /* CSR_TICLR: clear timer interrupt    */

    /* 2. Stack pointer: top of DDR, below the fw_arg block            */
    li.w    $r3, STACK_TOP
    addi.w  $r3, $r3, -16

    /* 3. UART 16550 init: 8N1, divisor from UART_PCLK/UART_BAUD        */
    li.w    $r13, UART_BASE
    li.w    $r14, 0x80          /* LCR: DLAB=1                         */
    st.b    $r14, $r13, 3
    li.w    $r14, UART_DIV & 0xff       /* DLL                         */
    st.b    $r14, $r13, 0
    li.w    $r14, (UART_DIV >> 8) & 0xff /* DLM                        */
    st.b    $r14, $r13, 1
    li.w    $r14, UART_DIV_FRAC         /* DL3: Loongson frac divisor  */
    st.b    $r14, $r13, 2               /* (ignored by plain 16550s)   */
    li.w    $r14, 0x03          /* LCR: 8N1, DLAB=0                    */
    st.b    $r14, $r13, 3
    li.w    $r14, 0x47          /* FCR: enable+reset FIFOs, trig 4     */
    st.b    $r14, $r13, 2
    li.w    $r14, 0x00          /* MCR / IER: 0                        */
    st.b    $r14, $r13, 4
    st.b    $r14, $r13, 1

    /* 4. Clear .bss                                                   */
    la      $r12, __bss_start
    la      $r14, _end
    beq     $r12, $r14, 2f
1:  st.w    $r0, $r12, 0
    addi.w  $r12, $r12, 4
    bltu    $r12, $r14, 1b
2:

    /* 5. Boot banner (asm, before C runtime is fully trusted)         */
    la      $r15, banner_str
    li.w    $r13, UART_BASE
3:  ld.b    $r16, $r15, 0
    beq     $r16, $r0, 5f
4:  ld.b    $r14, $r13, 5       /* LSR                                 */
    andi    $r14, $r14, 0x20    /* THR empty                           */
    beq     $r14, $r0, 4b
    st.b    $r16, $r13, 0
    addi.w  $r15, $r15, 1
    b       3b
5:
    /* 6. Into C                                                       */
    bl      main

    /* main() never returns; park the core if it ever does             */
    la      $r15, halt_str
    li.w    $r13, UART_BASE
6:  ld.b    $r16, $r15, 0
    beq     $r16, $r0, 8f
7:  ld.b    $r14, $r13, 5
    andi    $r14, $r14, 0x20
    beq     $r14, $r0, 7b
    st.b    $r16, $r13, 0
    addi.w  $r15, $r15, 1
    b       6b
8:  b       8b

    .section .rodata
banner_str:
    .asciz "\r\nNSCSCC2026 mini bootloader v" BOOT_VERSION " (LA32R/chiplab)\r\n"
halt_str:
    .asciz "bootloader: halt\r\n"

/*
 * void boot_jump(u32 entry, u32 argc, u32 argv, u32 bpi)
 *
 * Enable the direct-mapping windows + PG and jump to the next stage.
 * a0/a1/a2 are reshuffled into the kernel's fw_arg convention:
 *   a0 = argc, a1 = argv, a2 = bpi
 * DMW0's VSEG follows the entry address so both 0x8******* and
 * 0xA******* linked kernels (ucore / Linux) work unchanged.
 */
    .text
    .globl boot_jump
boot_jump:
    move    $r12, $r4           /* t0 = entry                          */
    move    $r4,  $r5           /* a0 = argc                           */
    move    $r5,  $r6           /* a1 = argv                           */
    move    $r6,  $r7           /* a2 = bpi                            */
    move    $r7,  $r0           /* a3 = 0                              */

    li.w    $r13, 0x00000001    /* DMW1: VSEG=0 -> PSEG=0 (identity),  */
    csrwr   $r13, 0x181         /*       MAT=0 (uncached), PLV0        */
    li.w    $r14, 0xE0000000    /* DMW0: VSEG = entry[31:29], PSEG=0   */
    and     $r14, $r12, $r14
    ori     $r14, $r14, 0x1
    csrwr   $r14, 0x180

    dbar    0
    ibar    0

    li.w    $r13, 0x10          /* CRMD: PLV=0, IE=0, DA=0, PG=1       */
    csrwr   $r13, 0x0

    jirl    $r0, $r12, 0        /* no return                           */
