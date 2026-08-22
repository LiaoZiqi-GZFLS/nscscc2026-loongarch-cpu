# show/ — 决赛展示内容（T2026143250012561 · 夜神骇客 · 南方科技大学）

> 按要求组织：**soc/** 展示用到的 SoC 环境及生成好的 bit；**software/** 展示用到的所有软件源码及生成好的二进制；**doc/** 总体简要使用文档。

## 内容地图

```
show/
├── doc/
│   ├── demo.md              # ★ 总体使用文档（演示阶梯、地址表、上板步骤）
│   └── 展示流程指南.md       # Linux 启动演示流程与话术（评委问答备用）
├── soc/
│   ├── official-bits/       # CI 流水线上板比特流（功能/性能/系统测试）
│   │   ├── func_soc_top.bit             # 功能测试 58/58 × 3 种子
│   │   ├── perf_soc_top.bit             # 性能测试 20/20（105.887336 MHz）
│   │   ├── sys_soc_top_100mhz.bit       # 系统测试（100 MHz 稳定版）
│   │   └── clock_timing_validation_100mhz.txt
│   └── linux-demo/          # Linux 演示 SoC 环境（chiplab nscscc-team 平台 + myCPU）
│       ├── soc_top.bit                  # 演示比特流（CPU 25MHz，轮询串口）
│       ├── soc_top_irq.bit              # 实验比特流（UART 中断接出，备用）
│       ├── mycpu_top_linux_demo.v       # 该比特流对应的 CPU 网表
│       └── 00~02_*.tcl                  # 探测 / 烧写+装载 / 释放 CPU
└── software/
    ├── boot/                # mini bootloader 源码（PMON 替代，ELF loader）
    ├── ucore/               # ucore-loongarch32 演示（源码、脚本、文档）
    │   └── out/             # ucore.bin / ucore.elf（含 sh/ls 的 sfs initrd）
    └── linux/               # Linux 5.14-rc2 演示
        ├── start.bin / vmlinux.bin / load-sizes.txt   # 生成好的二进制
        ├── src-kernel/      # 内核侧改动源码（DTS / .config / 汇编 shell init.S）
        └── scripts/         # demo_launcher.py 一键演示 + 串口工具
```

## 与 src/ 的一致性说明

- `src/` 为**初赛 CI 性能最强版**（t26-submit @ 0fbfaa1 提交链，官方 pipeline 1674/1675：
  system counter ratio 3.817781304，105.887336 MHz，功能 58/58，性能 20/20），
  叠加决赛系统测试修复（t26-final 链：CPUCFG 常量表、PRELD 合法 nop、TLB 重名优先等，
  详见 `sw/RUNBOOK.md`）。
- `show/soc/linux-demo/` 的演示比特流在系统测试链基础上另含 D-cache staging 加固
  （25 MHz 演示钟，不影响功能正确性），对应网表已随目录附带，便于核对。
- `show/soc/official-bits/` 为 CI 原生比特流，与本仓库根目录 `bit/` 一致。

## 演示阶梯（详见 doc/demo.md）

bootloader 串口输出 → ucore（sh/ls）→ Linux 启动 → Linux 交互 shell。
