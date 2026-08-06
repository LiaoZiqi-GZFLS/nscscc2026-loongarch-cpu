/*
 * start.S — T2026143250012561 chiplab LA32R Linux 引导 stub
 *
 * 基于 chiplab nscscc2026 software/examples/linux/start.S 改造：
 *   1. 初始化 16550 串口（0x1fe001e0，除数=1），打印引导信息；
 *   2. 配置直接映射窗口 DMW0/1（0xa0000000 uncached / 0x80000000 cached
 *      均映射到物理 0x0），开 PG；
 *   3. 按 fw_arg 约定设置 a0~a2 后跳转 kernel_entry：
 *        a0 = argc = 2
 *        a1 = argv 指针（本文件内嵌，uncached 虚址 = 链接地址 + 0xa0000000）
 *        a2 = bootparam 区指针（全 0，内核按 bootparamsinterface 解析，
 *             全 0 即无扩展链表，与 chiplab 官方流程行为一致）
 *
 * 链接：objcopy -O binary 生成 start.bin，加载/复位地址 = 0x1c000000。
 * 内核命令行在下方 CMDLINE 处修改（默认 console=ttyS0,115200 rdinit=/init）。
 */

	.text
	.globl	_start
_start:
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
	li.w	$t2, 0x40		/* DL3: fractional divisor for the Loongson URT */
	st.b	$t2, $t1, 2
	li.w	$t2, 0x3		/* LCR: 8N1 */
	st.b	$t2, $t1, 3
	li.w	$t2, 0x0		/* MCR */
	st.b	$t2, $t1, 4

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

	/* ---- 直接映射窗口：与内核 head.S 一致 ---- */
	li.w	$t2, 0xa0000001		/* DMW0: 0xa0000000 cached -> phys 0 */
	csrwr	$t2, 0x180
	li.w	$t2, 0x00000001		/* DMW1: 0x00000000 uncached -> phys 0 */
	csrwr	$t2, 0x181

	/* ---- CRMD: 清 DA(0x8) 置 PG(0x10) ---- */
	li.w	$t2, 0x10
	li.w	$t3, 0x18
	csrxchg	$t2, $t3, 0x0

	/* ---- fw_arg 约定并跳转内核 ---- */
	li.w	$a0, 0x2		/* argc = 2 */
	la.abs	$a1, argv
	la.abs	$a2, bootparam
	li.w	$t3, 0xa0000000		/* 0xa0000000：phys -> uncached 虚址 */
	or	$a1, $a1, $t3		/* argv（uncached 虚址） */
	or	$a2, $a2, $t3		/* bootparam 区（全 0） */
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
	.word	str_g    + 0xa0000000
	.word	str_args + 0xa0000000
	.word	0
str_g:
	.string	"g"
str_args:
	.string	CMDLINE " rd_start=0x1c900000 rd_size=1312992"

	.align	8
bootparam:
	.space	256, 0
