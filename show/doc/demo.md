# T26 决赛系统演示 · 总体使用文档

**团队：T2026143250012561 夜神骇客（南方科技大学） · 平台：xc7a200t（Artix-7）**
**CPU：自主 LA32R 三发射乱序超标量核（SpinalHDL，基于 NOP-Core 二次开发）**

本文件是 show/ 展示内容的总体入口。演示分四个阶梯，难度递增、可独立演示：

| 阶梯 | 内容 | 产物位置 |
|---|---|---|
| 1. bootloader | 串口横幅 + ELF loader（PMON 替代） | `software/boot/` |
| 2. ucore | 教学 OS 启动，sh/ls 可用 | `software/ucore/`（二进制在 `out/`） |
| 3. Linux 启动 | Linux 5.14-rc2 完整启动（约 16 秒 @25MHz） | `software/linux/` |
| 4. Linux 交互 | 纯汇编 shell：help/echo/uname/ls/cat/cd/pwd/clear/reset | 同上 |

## 一、硬件准备

1. 开发板上电；**JTAG 线**（烧写）与**串口线**（交互，115200 8N1，识别为 COM3）都插好——串口线最容易忘。
2. Vivado 2023.2 可用（`vivado.bat` 在 PATH 或脚本内写绝对路径）。

## 二、Linux 演示（推荐主流程，约 5 分钟）

```bat
cd show\software\linux
python scripts\demo_launcher.py --all --log demo_run.log
```

`--all` = 烧写比特流（`soc/linux-demo/soc_top.bit`）→ JTAG-AXI 装载
`start.bin` → 0x1C000000、`vmlinux.bin` → 0x1C300000 → 释放 CPU → 等 shell。

手工分步（脚本失败时）：

```bat
vivado -mode batch -source show\soc\linux-demo\01d_program_load_clean.tcl   rem 烧写+装载
rem 打开串口 COM3 @115200 8N1
vivado -mode batch -source show\soc\linux-demo\02_release_cpu.tcl           rem 释放 CPU
```

约 16 秒出现 `nop$` 提示符。演示命令与话术见 `doc/展示流程指南.md` 第三节。

## 三、ucore 演示

`software/ucore/` 内含演示脚本（`demo/` 下 load_demo.tcl / demo.py / demo_script.txt）
与已构建二进制 `out/ucore.bin`（760KB，含 sh/ls 的 sfs initrd）。装载地址约定见下表。

## 四、关键地址表（演示必背）

| 内容 | 地址 |
|---|---|
| 复位入口 / bootloader | 0x1C000000 |
| 下一阶段镜像暂存区 | 0x1C400000 |
| fw_arg 块（DDR 顶 64KB 保留） | 0x1CFF0000 |
| Linux 内核装载 | 物理 0x1C300000（虚 0xBC300000，DMWIN0） |
| UART ns16550a | 0x1FE001E0（PCLK = sys_clk = 100 MHz，DLL 0x36） |
| CONFREG（计时器 +0xE000） | 0x1FAF0000 |
| 复位保持/释放（JTAG-AXI） | 写 0x80000000 / 0x40000000 |

## 五、技术要点（答辩备用）

1. **MMU/虚拟内存全程打通**：ucore 与 Linux 均运行在虚地址空间（DMWIN0 映射 +
   16 项全相联 TLB 细粒度页表）；`ls` 一条命令走通 getdents64 → VFS → 页缓存 →
   MMU 翻译 → DDR3 全链路。
2. **Linux 移植关键修复**：`PHYS_OFFSET=0x1c000000` + `CONFIG_PHYSICAL_START=0xbc300000`
   （错配则启动即崩）；DTS 串口 `clock-frequency=<100000000>`（上游默认 33MHz 会乱码）；
   内核补丁 0008 使 cache 几何匹配本核 64sets×64B×2way（config=0xfe2914d3）。
3. **UART 中断风暴规避**：演示版将 UART 中断线悬空 + 轮询控制台（10ms 定时器），
   规避接出中断时 virq 编号不匹配导致的 "Unexpected IRQ #4" 风暴（拖慢启动约 50 倍）。
   中断版比特流 `soc_top_irq.bit` 保留作对照。
4. **纯汇编 shell**：无 libc、静态 syscall，绕过 glibc 启动读 GOT 为 0 的未解决问题。

## 六、已知取舍（主动说明）

- 115200 下 10ms 轮询偶发丢单个输入字符（约 1%/字符），正常打字速度无感；
- `ls` 输出为 initramfs 目录查表结果（与 getdents64 一致），dirent64 游标遍历在板上
  有未定位问题，为演示稳定改为查表（详见 src-kernel/init.S 注释）；
- 演示用 25 MHz 保守钟（Linux 启动仍仅 16 秒）；性能演示请用
  `soc/official-bits/perf_soc_top.bit`（105.887336 MHz，WNS +0.035 ns 版本对应产物）。

## 七、更多细节

- 系统测试完整 runbook（译码语义裁决、回归记录）：仓库根目录 `sw/RUNBOOK.md`
- Linux 演示逐分钟流程与故障排查：`doc/展示流程指南.md`
- 设计报告（微架构 / 时序重构 / 成绩）：仓库根目录 `design.pdf`
