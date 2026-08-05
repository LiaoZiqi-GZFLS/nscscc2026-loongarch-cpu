# NSCSCC2026 mini bootloader (sw/boot)

面向龙芯杯 2026 团体赛 chiplab 平台（`nscscc2026` 分支，nscscc-team 最小 SoC）
的最小 bootloader，用于在决赛"bootloader"里程碑中链式加载 ucore / Linux
（la32r-Linux 5.14）镜像。

## 平台事实（chiplab nscscc-team SoC）

| 资源 | 地址 | 说明 |
|---|---|---|
| DDR3 | `0x1C000000`，16MB 窗口 | CPU 复位后从 `0x1C000000` 取指（DA 模式） |
| UART16550 | `0x1FE001E0` | Loongson URT 核，挂 AXI-APB 桥（sys_clk 域） |
| CONFREG | `0x1FAF0000` | 数码管/计时器（本 bootloader 未使用） |
| JTAG-AXI | 全地址空间 | 上板下载/调试通道（crossbar 第二 slave） |

## 构建

```sh
cd sw/boot
make            # 产出 boot.elf + boot.bin
make check      # readelf + objdump 检查（ELF32/LoongArch/入口/禁 AM、FP 指令）
```

工具链：`/home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf-gcc`（8.3.0, ilp32s
软浮点）。可用 `CROSS_COMPILE=` 覆盖。常用选项：

```sh
make EXTRA="-DUART_PCLK=33000000"      # UART 时钟非 100MHz 时
make EXTRA="-DBOOT_RAW_BINARY"         # 下一阶段是裸 bin（不解析 ELF）
make EXTRA="-DBOOT_CMDLINE=\"console=ttyS0,115200 rdinit=/init\""
```

## 上板流程（JTAG-AXI 灌镜像）

镜像布局约定（与 Vivado `jtag_axi_master.tcl` 相同的方式写 DDR）：

| 物理地址 | 内容 |
|---|---|
| `0x1C000000` | `boot.bin`（本 bootloader，CPU 复位取指处） |
| `0x1C400000` | 下一阶段镜像（vmlinux/uCore 的 **ELF** 文件整体，或裸 bin） |

流程：Hardware Manager 下载 bit → `source jtag_axi_master.tcl` →
依次把 `boot.bin` 写到 `0x1C000000`、把下一阶段 ELF 写到 `0x1C400000` →
释放 CPU 复位（先 `WriteReg 80000000 00000000` 复位核，写完再放行）。
串口（115200 8N1）可见 banner、ELF segment 拷贝信息和跳转日志。

## 与下一阶段镜像的接口约定

### 1. ELF 加载

- 默认解析 `0x1C400000` 处的 ELF32（e_machine 应为 LoongArch=258，仅告警不拦截）。
- 对每个 `PT_LOAD`：目的地址取 `p_paddr`（为 0 则 `p_vaddr`）；
  若地址 ≥ `0x80000000` 则按 `addr & 0x1FFFFFFF` 折叠为物理地址（kseg→phys）。
  `p_filesz` 拷贝 + `p_memsz` 剩余清零。
- **下一阶段镜像的物理装载地址必须落在 DDR 窗口 `0x1C000000~0x1CFFFFFF`
  之内**（比赛 SoC 在 `0x00000000` 处没有 RAM；chiplab 自带 linux 例程把
  vmlinux.bin 放 `0x300000` 是面向 soc_demo/loongson 全功能 SoC 的，不能直接套用）。
- 跳转到 `e_entry`（虚拟地址原样跳转，见下）。
- 裸 bin 模式（`-DBOOT_RAW_BINARY`）：不拷贝，直接跳 `RAW_ENTRY`
  （默认 `0x1C400000`）。

### 2. 跳转时的机器状态（与 chiplab linux 例程 start.S 一致）

```
DMW0 = (entry & 0xE0000000) | 0x1   # VSEG=entry[31:29] -> PA 0x0, MAT=0 uncached, PLV0
DMW1 = 0x00000001                   # VA 0x00000000-0x1FFFFFFF -> PA 恒等, uncached, PLV0
CRMD = 0x10                         # PLV=0, IE=0, DA=0, PG=1
```

因此无论下一阶段链接在 `0x8*******`（ucore 风格）还是 `0xA*******`
（la32r-Linux 风格），都能直接跳转；ucore 入口会自行重写 DMW/CRMD，Linux
head.S 也会自建窗口，互不冲突。

### 3. fw_arg（la32r-Linux 5.14 old-world 协议）

依据 `arch/loongarch/kernel/cmdline.c`、`loongson32/env.c`、`loongson32/mem.c`、
`include/asm/mach-loongson32/boot_param.h`：

```
a0 = argc = 2
a1 = argv  ->  { "boot", "<cmdline>", NULL }
a2 = bpi   ->  struct bootparamsinterface { "BPI01000", systemtable=0,
               extlist=&mem_node, flags=0 }
mem_node: hdr { u64 "MEM"; u32 length; u8 rev; u8 checksum; u32 next=NULL }
          u8 map_count; map[] { u32 mem_type, mem_start, mem_size }  (packed)
          checksum: 节点前 length 字节累加和 ≡ 0 (mod 256)
```

块位于 `0x1CFF0000`（DDR 顶端 64KB），指针均为 `0xA0000000|phys` 虚拟地址
（经内核 DMW0 窗口可达）。默认内容：

- cmdline：`console=ttyS0,115200`（`BOOT_CMDLINE` 可覆盖，按需加
  `rd_start=`/`rd_size=`/`rdinit=`/`loglevel=`）
- MEM 链表：`SYSRAM 0x1C000000 +16MB`、`RESERVED 0x1CFF0000 +64KB`

**注意**：la32r-Linux 的 `platform_init()` 会用内置 DTB（`loongson32_ls.dts`
的 memory 节点）重建内存图并覆盖 fw MEM 链表，因此移植内核时**必须**把
dts memory 节点改成 `reg = <0x1c000000 0x01000000>`；fw MEM 链表在
`early_init()` 阶段生效，并对未来直接消费 BPI 的内核/PMON 兼容件保持正确。
串口时钟同理：内核 dts 中 16550 的 `clock-frequency` 应填 **100000000**
（sys_clk），否则内核重设波特率后会乱码。

## 波特率默认值与校准

- 默认 `UART_PCLK=100MHz`、`115200 8N1`，除数锁存器 DLL=54, DL3(小数)=64
  （URT 为 24bit 小数分频：`baud = PCLK/(16*dl)`，见 `IP/APB_DEV/URT/uart_regs.v`）。
  实际 115212 baud，误差 -0.06%。
- 依据：`soc_top.v` 中 UART 经 axi2apb 挂在 `sys_clk`；`clk_pll.xci` 的
  `clk_out2(sys_clk)=100MHz`（比赛规则只允许改 cpu_clk/clk_out1）。
- 校准方法：若串口乱码，先确认实际 sys_clk（看 clk_pll/perf_clock.json 生成
  的 Clock Wizard 配置），`make EXTRA="-DUART_PCLK=<实际频率>"` 重编；
  也可发送 `'U'`(0x55) 用示波器/逻辑分析量位宽反推时钟。仿真（verilator）
  的 UART 模型不校验波特率，乱码问题只在上板时出现。

## 文件

- `start.S` — 复位入口：CRMD/关中断/栈/UART 初始化、清 bss、banner、
  `boot_jump()`（DMW+PG+跳转）
- `main.c` — 信息打印、ELF32 loader、fw_arg 构建、跳转
- `boot.h` — 地址/波特率/协议常量（全部可宏覆盖）
- `linker.ld` — 链接到 `0x1C000000`，入口 `_start`
- `Makefile` — 产出 `boot.elf`/`boot.bin`，`make check` 验收
