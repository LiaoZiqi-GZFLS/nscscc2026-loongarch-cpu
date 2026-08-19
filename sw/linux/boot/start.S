/*
 * start.S — T2026143250012561 chiplab LA32R Linux 引导 stub
 *
 * 基于 chiplab nscscc2026 software/examples/linux/start.S 改造：
 *   1. 初始化 16550 串口（0x1fe001e0，100MHz 时钟下 115200 8N1），打印引导信息；
 *   2. 配置直接映射窗口 DMW0/1（0xa0000000 uncached / 0x80000000 cached
 *      均映射到物理 0x0），开 PG；
 *   3. 按 fw_arg 约定设置 a0~a2 后跳转 kernel_entry：
 *        a0 = argc = 2
 *        a1 = argv 指针（本文件内嵌，uncached 虚址 = 链接地址 + 0xa0000000）
 *        a2 = BPI01000 bootparamsinterface（含有效 MEM 扩展节点）
 *
 * 链接：objcopy -O binary 生成 start.bin，加载/复位地址 = 0x1c000000。
 * 内核命令行在下方 CMDLINE 处修改（默认 console=ttyS0,115200 rdinit=/init）。
 */

	.text
	.equ	MEM_NODE_LEN, 31
	.globl	_start
_start:
	li.w	$t3, 0x1c220000
	li.w	$t4, 0x424f4f54		/* BOOT: reset entry reached */
	st.w	$t4, $t3, 0x70

	/* ---- 串口 16550 @0x1fe001e0 初始化（与 chiplab 官方一致）---- */
	li.w	$t1, 0x1fe001e0
	li.w	$t2, 0x47		/* FCR: enable, rcv/xmt rst, trigger 4 */
	st.b	$t2, $t1, 2
	li.w	$t2, 0x80		/* LCR: DLAB=1 */
	st.b	$t2, $t1, 3
	li.w	$t2, 0x36		/* DLL: 100MHz / (16 * 115200) */
	st.b	$t2, $t1, 0
	li.w	$t2, 0x0		/* DLM */
	st.b	$t2, $t1, 1
	li.w	$t2, 0x40		/* DL3: fractional divisor */
	st.b	$t2, $t1, 2
	li.w	$t2, 0x3		/* LCR: 8N1 */
	st.b	$t2, $t1, 3
	li.w	$t2, 0x0		/* MCR */
	st.b	$t2, $t1, 4
	li.w	$t4, 0x55415254		/* UART: initialization completed */
	st.w	$t4, $t3, 0x74

	/* ---- 打印 "boot\n" ---- */
	li.w	$t5, 0x62		/* b */
	bl	print_char
	li.w	$t5, 0x6f		/* o */
	bl	print_char
	li.w	$t5, 0x6f		/* o */
	bl	print_char
	li.w	$t5, 0x74		/* t */
	bl	print_char
	li.w	$t5, 0x0a		/* \n */
	bl	print_char
	li.w	$t3, 0x1c220000
	li.w	$t4, 0x50524e54		/* PRNT: boot text transmitted */
	st.w	$t4, $t3, 0x78

	/* ---- 直接映射窗口：与内核 head.S 一致 ---- */
	li.w	$t2, 0xa0000011		/* DMW0: 0xa0000000 cached -> phys 0 */
	csrwr	$t2, 0x180
	li.w	$t2, 0x00000001		/* temporary mapping for physical boot PC */
	csrwr	$t2, 0x181

	/* ---- CRMD: 清 DA(0x8) 置 PG(0x10) ---- */
	li.w	$t2, 0x10
	li.w	$t3, 0x18
	csrxchg	$t2, $t3, 0x0

	/* ---- fw_arg 约定并跳转内核 ---- */
	li.w	$a0, 0x2		/* argc = 2 */
	la.abs	$a1, argv
	la.abs	$a2, bootparam
	li.w	$t3, 0x80000000		/* physical address -> DMW0 uncached alias */
	or	$a1, $a1, $t3		/* argv */
	or	$a2, $a2, $t3		/* bootparam */
	li.w	$t3, 0xbc220000
	li.w	$t4, 0x4a554d50		/* JUMP: kernel entry next */
	st.w	$t4, $t3, 0x7c
	la.abs	$t2, 1f
	li.w	$t3, 0xa0000000
	or	$t2, $t2, $t3		/* continue through DMW0 before replacing DMW1 */
	jirl	$zero, $t2, 0
	1:	li.w	$t3, 0xa0000011	/* DMW1: cached, physical segment 0 */
	csrwr	$t3, 0x181
	li.w	$t3, 0x80000001	/* DMW0: uncached, physical segment 0 */
	csrwr	$t3, 0x180
	li.w	$t2, KERNEL_ENTRY_ADDRESS
	jirl	$zero, $t2, 0

/* 等待发送 FIFO 空后写 THR */
print_char:
1:	ld.b	$t2, $t1, 5		/* LSR */
	andi	$t2, $t2, 0x20		/* THRE */
	beq	$t2, $zero, 1b
	st.b	$t5, $t1, 0
	jirl	$zero, $ra, 0

/* ---- 内嵌 argv / 命令行 / bootparam 区 ---- */
	.align	4
argv:
	.word	str_g    + 0x80000000
	.word	str_args + 0x80000000
	.word	0
str_g:
	.string	"g"
str_args:
	.string	CMDLINE

	.align	8
bootparam:
	.ascii	"BPI01000"
	.word	0			/* systemtable */
	.word	mem_node + 0x80000000	/* extlist */
	.word	0			/* flags low */
	.word	0			/* flags high */

mem_node:
	.ascii	"MEM"
	.space	5, 0
	.word	MEM_NODE_LEN
	.byte	0			/* revision */
mem_checksum:
	.byte	0xe3			/* byte sum over this 31-byte node is zero */
	.word	0			/* next */
	.byte	1			/* map_count */
	.word	1, 0x1c000000, 0x01000000	/* SYSRAM */
