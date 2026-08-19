# LA32R FPGA Linux 早期启动问题请教

学长你好，我目前在 LA32R FPGA SoC 上启动 Linux，启动桩已经能够跳入当前 Linux ELF entry，但内核没有输出 banner。想请你帮忙确认启动时的地址映射、CRMD/DMW 配置，以及当前诊断值的含义。

## 1. 硬件与镜像布局

- FPGA 主频：80 MHz
- UART：16550，基地址 `0x1fe001e0`
- UART 参数：115200 8N1
- RAM：物理地址 `0x1c000000` 起，大小 16 MB
- 启动桩加载地址：`0x1c000000`
- Linux `vmlinux.bin` 加载地址：`0x1c300000`
- Linux ELF 链接地址：`0xbc300000`
- Linux ELF entry：`0xbc593b50`

ELF program header 如下：

```text
Type  Offset    VirtAddr    PhysAddr    FileSiz   MemSiz
LOAD  0x001000  0xbc300000  0xbc300000  0x574e24  0x5f111c
```

实际镜像通过 JTAG AXI 写入 DDR 的 `0x1c300000`。

## 2. 启动桩当前流程

启动桩从物理地址 `0x1c000000` 执行，初始化 UART 后配置 DMW 和 CRMD：

```asm
/* DMW0 */
li.w    $t2, 0xa0000001
csrwr   $t2, 0x180

/* DMW1 */
li.w    $t2, 0x00000001
csrwr   $t2, 0x181

/* 清 DA，置 PG */
li.w    $t2, 0x10
li.w    $t3, 0x18
csrxchg $t2, $t3, 0x0

/* Linux firmware arguments */
li.w    $a0, 2
la.abs  $a1, argv
la.abs  $a2, bootparam
li.w    $t3, 0xa0000000
or      $a1, $a1, $t3
or      $a2, $a2, $t3

/* ELF entry */
li.w    $t2, 0xbc593b50
jirl    $zero, $t2, 0
```

当前这段代码在切换 PG 前没有执行 `dbar 0` 或 `ibar 0`。

## 3. Linux 入口反汇编

当前 ELF header 和反汇编都确认 entry 是 `0xbc593b50`：

```asm
bc593b50: 1578b26c  lu12i.w  $r12, ...
bc593b54: 03ad718c  ori       $r12, $r12, 0xb5c
bc593b58: 4c000180  jirl      $r0, $r12, 0

bc593b5c: 1c005d8c  pcaddu12i $r12, ...
bc593b60: 0292918c  addi.w     $r12, $r12, ...
bc593b64: 29800180  st.w       $r0, $r12, 0
```

对应 Linux `arch/loongarch/kernel/head.S`：

```asm
kernel_entry:
    la.abs  t0, 0f
    jirl    zero, t0, 0
0:
    la      t0, __bss_start
    PTR_S   zero, t0, 0
    ...

    PTR_LI  t0, 0xa0000011
    csrwr   t0, LOONGARCH_CSR_DMWIN0
    PTR_LI  t0, 0x80000001
    csrwr   t0, LOONGARCH_CSR_DMWIN1

    li.w    t0, 0xb0
    csrwr   t0, LOONGARCH_CSR_CRMD
```

也就是说，Linux 自己会在清 `.bss` 和保存 firmware arguments 后重新配置 DMW，并写入 `CRMD=0xb0`。

## 4. 已排除的入口地址问题

之前启动桩错误地跳到了旧地址 `0xbc593b40`：

```asm
bc593b40: jirl $r0, $r1, 0
```

这实际上是前一个函数的返回指令，不是当前内核入口。

目前已改为 ELF entry `0xbc593b50`，并在 `start.elf` 中确认最终指令为：

```asm
li.w $r14, 0xbc593b50
jirl $r0, $r14, 0
```

## 5. 当前运行现象

启动桩在 RAM 中写入了四个阶段标记：

```text
0x1c220070 = 0x424f4f54  "BOOT"
0x1c220074 = 0x55415254  "UART"
0x1c220078 = 0x50524e54  "PRNT"
0x1c22007c = 0x4a554d50  "JUMP"
```

四个标记都能读到，因此可以确认：

1. CPU 从 `0x1c000000` 正常执行；
2. UART 初始化完成；
3. 启动桩执行到跳转 Linux 前；
4. 跳转目标已经改为当前 ELF entry。

跳入 Linux 后：

- UART 只收到两个字节：`00 0a`；
- 没有 Linux banner；
- 没有 BusyBox shell；
- 诊断区域还读到：

```text
0x1c220000 = 0x1c2201c0
0x1c220008 = 0x0101fefe
```

目前不确定这两个值是 CPU/SoC 调试模块写入的状态，还是异常处理过程中产生的数据。

## 6. 复位时序现象

通过 JTAG AXI 控制 CPU reset 时：

- assert 约 100 ms 再 release，有时 CPU 不会重新执行启动桩；
- assert 约 1 秒再 release，可以稳定看到 `BOOT/UART/PRNT/JUMP`。

不确定 reset 是否有跨时钟域同步、最小保持时间或特殊 release 要求。

## 7. 想重点请教的问题

### 问题一：进入 `kernel_entry` 时应使用 DA 还是 PG 模式？

对于以下组合：

```text
Linux 链接地址：0xbc300000
Linux 实际加载地址：0x1c300000
ELF entry：0xbc593b50
```

启动桩应该：

1. 保持 `DA=1, PG=0`，跳到某个物理入口；还是
2. 先配置 DMW，切换到 `DA=0, PG=1`，再跳到 `0xbc593b50`？

Linux `head.S` 是否假设进入 `kernel_entry` 时 DMW/PG 已经可用？

### 问题二：当前 DMW 值是否正确？

请问在这个 LA32R CPU 实现中：

```text
DMW0 = 0xa0000001
DMW1 = 0x00000001
```

分别映射哪些虚拟地址范围和物理地址范围？

特别想确认：`0xbc593b50` 是否会通过 `DMW0=0xa0000001` 映射到实际 DDR 地址 `0x1c593b50`。

另外，Linux `head.S` 随后写入：

```text
DMW0 = 0xa0000011
DMW1 = 0x80000001
```

这组值与启动桩的配置不一致。这里是否存在 MAT、VSEG、PSEG 或窗口编号理解错误？

### 问题三：切换 CRMD 前是否必须执行屏障？

参考另一个启动程序，切换到 PG 模式前会执行：

```asm
dbar 0
ibar 0
li.w  $r13, 0x10
csrwr $r13, 0x0
```

当前 Linux 启动桩没有 `dbar/ibar`，并且使用 `csrxchg` 修改 DA/PG 位。

请问是否应该改为：

```asm
dbar 0
ibar 0
li.w  $t0, 0x10
csrwr $t0, CRMD
```

直接写完整 CRMD，而不是使用 `csrxchg`？

### 问题四：诊断值代表什么？

请问当前 SoC 中以下地址是否映射了 CPU 调试状态：

```text
0x1c220000
0x1c220008
0x1c2201c0
```

其中：

```text
0x1c220008 = 0x0101fefe
0x1c2201c0 = 0x1c220000
```

是否可以解码为 ESTAT、ERA、BADV、EENTRY、TLBR 状态、当前 PC 或流水线异常码？

如果这些不是标准诊断寄存器，推荐从哪里读取以下 CSR：

```text
CRMD
PRMD
ESTAT
ERA
BADV
EENTRY
TLBRENTRY
TLBRBADV
TLBREPC
TLBRPRMD
```

### 问题五：TLB refill 返回状态

这个 CPU 此前修复过 `TLBR` 返回后恢复分页状态的问题。想确认 Linux early boot 期间如果发生 TLB refill：

- `TLBR` 返回时应如何恢复 `CRMD.DA/PG`；
- 返回地址应为异常指令还是下一条指令；
- `TLBRPRMD` 与普通 `PRMD` 的恢复关系；
- `kernel_entry` 第一段重定位是否可能触发 instruction TLB refill；
- 如何区分 instruction TLB miss、取指权限异常和非法指令异常。

### 问题六：CPU reset 时序

CPU reset 通过 JTAG AXI 写寄存器控制。请问：

- reset 是电平有效还是脉冲有效；
- 是否有最小 assert 时间；
- release 前是否需要等待 DDR/JTAG AXI 空闲；
- 是否存在跨时钟域同步要求；
- 为什么 100 ms 有时无效，而 1 秒基本稳定。

## 8. 最希望先确认的三点

如果时间有限，希望先帮忙确认下面三点：

1. `0xbc300000` 链接、`0x1c300000` 加载的 Linux，进入 `kernel_entry` 前正确的 DA/PG/DMW 状态是什么？
2. `DMW0=0xa0000001`、`DMW1=0x00000001` 在当前 CPU 实现中能否让 `0xbc593b50` 正确映射到 `0x1c593b50`？
3. `0x1c220008=0x0101fefe` 和 `0x1c2201c0=0x1c220000` 分别表示什么？

如果有一段在该 SoC 上已知可工作的 Linux 最小跳转代码，包括 CRMD、DMW、屏障、入口地址和 reset 时序，麻烦发我参考一下。这样可以避免继续通过完整镜像加载反复试错。
