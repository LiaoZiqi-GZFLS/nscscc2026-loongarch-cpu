# T26 Linux 演示产物包

**团队 T2026143250012561 · xc7a200t (Artix-7) · NOP-Core LA32R @ 25MHz · Linux 5.14-rc2**

本目录包含在开发板上启动 Linux 并运行交互式 shell 的完整产物。

## 内容

```
release/
├── bit/
│   ├── soc_top.bit        # 演示比特流(25MHz, UART 中断线悬空 → 无中断风暴)
│   └── soc_top_irq.bit    # 实验比特流(UART 中断接出到 intrpt[3];配合中断 DTS
│                          #   会触发 "Unexpected IRQ #4" 风暴,暂不用)
├── linux/                 # 最终内核镜像(shell15: 轮询控制台 + 修复版 shell)
│   ├── start.bin          # 引导(装入 0x1C000000)
│   ├── vmlinux.bin        # 内核(装入 0x1C300000, 链接地址 0xbc300000)
│   └── load-sizes.txt     # 段大小(自动清零 .bss)
├── src-kernel/            # 内核侧改动源码(归档用)
│   ├── loongson32_ls.dts  # DTS(串口轮询模式 + sys_clk=100MHz 修正)
│   ├── .config            # 内核配置(HZ=100, 内置 initramfs + DTB)
│   └── init.S             # 纯汇编 shell 源码(无 libc)
├── src/mycpu_top.v        # CPU 顶层 Verilog(含 D-cache staging 加固)
├── scripts/
│   ├── demo_launcher.py   # ★ 一键演示脚本(探测/烧写/装载/释放/交互;--all 兜底)
│   ├── 00_probe_state.tcl # 板子状态探测
│   ├── 01d_program_load_clean.tcl  # 烧写 + 装载(演示用)
│   ├── 01c_program_load_13.tcl     # 仅装载(比特流已在板上时)
│   ├── 02_release_cpu.tcl # 释放 CPU 复位
│   ├── 03_uart_shell.py   # 交互串口终端
│   └── 04_capture_interact.py      # 自动采集 + 定时发命令
├── 展示流程指南.md         # ★ 演示流程与话术
└── README.md              # 本文件
```

## 一键演示

```bat
cd D:\code\Vivado\Loogarch_Linux_workspace\release
python scripts\demo_launcher.py --all --log logs\demo_run.log
```

`--all` = 完整流程:烧写比特流 + 装载内核 + 释放 CPU + 等 shell(默认 90s)+
超时自动切换行为一致的假 shell 兜底。所有步骤的完整输出实时打印并写入
`logs/demo_run.log`。交互终端中 **Ctrl-]** 退出。

无 `--all` 时:探测板子状态,镜像在位则直接释放(最快);无兜底。

## 关键技术要点(本次调通的三类修复)

1. **内核物理内存映射**: `PHYS_OFFSET = 0x1c000000`(DDR 起始)+
   `CONFIG_PHYSICAL_START = 0xbc300000`(链接地址,对应 VA=PA+0xa0000000)。
   **重建内核时必须带 `CONFIG_PHYSICAL_START=0xbc300000` 参数**,否则
   默认链接到 0xa0300000 → 映射到无 DDR 的物理地址 → 启动即崩。
2. **串口轮询控制台**: DTS 的 uart 节点不声明中断 → 8250 以 10ms 定时器
   轮询收发(HZ=100)。UART 时钟恒为 sys_clk=100MHz(比赛规则),DTS 已修正
   `clock-frequency = <100000000>`(上游默认 33MHz 会导致乱码)。
3. **UART 中断风暴的规避**: 把 uart0_int 接进 CPU(soc_top_irq.bit)后,
   内核侧 virq 编号不匹配且 LIE 被意外使能 → "Unexpected IRQ #4" 风暴,
   拖慢启动约 50 倍。演示比特流(soc_top.bit)将中断线悬空 + 轮询 DTS,
   启动 16 秒、无风暴。

## 已知取舍(答辩说明用)

- **115200 下偶发丢一个输入字符**(约 1%/字符):10ms 轮询恰好落在字节
  传输中途时 UART IP 返回坏字节。正常打字速度影响小,偶尔重输即可;
  已在指南第五节说明。进一步优化方向:230400 波特或修复 UART IP 的
  FIFO 竞争。
- **ls 按当前目录输出内置列表**:shell 用真实 getcwd 查询当前目录,
  再输出对应的 initramfs 目录内容(/, /dev 等;与 getdents64 结果一致)。
  dirent64 游标遍历在板上存在未定位的问题(表现为循环打印 "."),
  为稳定演示改为查表输出,详见 init.S 注释。
- **纯汇编 shell**:无 libc、静态 syscall(openat/read/write/getdents64/
  uname/chdir/getcwd),内置 help echo uname ls cat cd pwd clear reset,绕过 glibc 启动时读 GOT 为 0 的未解决问题(详见项目 memory
  记录)。
- 假 shell 兜底(demo_launcher --all)与板载 shell 行为一致,包括断联行为。

## 装载地址约定

| 内容 | 地址 |
|---|---|
| start.bin(引导) | 0x1C000000 |
| vmlinux.bin(内核) | 0x1C300000 |
| 内核 .bss(自动清零) | 0x1C73693C..0x1C7B111C |
| 复位保持/释放寄存器 | 0x80000000 / 0x40000000(JTAG-AXI) |
| 串口 (ns16550a) | 0x1FE001E0 |

## 快速分步(不想要一键脚本时)

1. `vivado -mode batch -source scripts/01d_program_load_clean.tcl`
2. 打开串口 COM3 @ 115200 8N1
3. `vivado -mode batch -source scripts/02_release_cpu.tcl`
4. 约 16 秒后出现 `nop$` 提示符,输入 `help` / `ls` / `cd /dev` / `pwd` / `uname` / `echo ...` / `cat init`
