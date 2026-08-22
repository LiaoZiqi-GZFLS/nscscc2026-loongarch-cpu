/*
 * demo_start.S - entry of the bootloader showcase payload
 *
 * Entered via the bootloader's boot_jump(): a0=argc, a1=argv, a2=bpi
 * (all KVIRT pointers into the fw_arg block).  Saves the handoff
 * registers, sets up a private stack, clears .bss and calls main().
 * Runs entirely inside the windows the bootloader configured
 * (DMW0: 0xa******* cached window, DMW1: identity window).
 */
    .text
    .globl _start
_start:
    la      $r3,  stack_top
    addi.w  $r3,  $r3, -16

    /* clear .bss（saved_a0/1/2 位于 .bss，必须先清再保存握手寄存器） */
    la      $r12, __bss_start
    la      $r13, _end
1:  beq     $r12, $r13, 2f
    st.w    $r0,  $r12, 0
    addi.w  $r12, $r12, 4
    b       1b
2:
    /* 保存 bootloader 握手寄存器 a0=argc, a1=argv, a2=bpi */
    la      $r12, saved_a0
    st.w    $r4,  $r12, 0
    st.w    $r5,  $r12, 4
    st.w    $r6,  $r12, 8
    bl      main
3:  b       3b

    .section .bss
    .global saved_a0, saved_a1, saved_a2
saved_a0:   .space 4
saved_a1:   .space 4
saved_a2:   .space 4
    .align  4
stack_top:  .space 4096
