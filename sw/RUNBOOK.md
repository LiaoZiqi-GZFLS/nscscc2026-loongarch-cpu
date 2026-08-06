# 夜神骇客 2026 龙芯杯决赛 · 系统测试上板 Runbook

> 分支：`t26-final`（基于初赛银行版 t26-submit@0fbfaa1）
> 目标阶梯：bootloader(5) → ucore(10) → Linux 启动(15) → Linux+ls(20)
> 本文件是上板前的唯一事实源；各子目录 README 为细节补充。

## 0. 当前交付全景（t26-final 提交链）

| commit | 内容 |
|---|---|
| aba0eea | RTL：CPUCFG 常量表 + CSR PRCFG1/2/3 + IOCSR×6 指令（面向主线/新内核保险；本赛事 5.14 内核 32 位路径不读，但对主线必需） |
| 922d588 | 文档：WNS@105MHz 风险项（**本 runbook 风险首位**） |
| f2e15e4 → 06f1776 | sw/ucore：ucore-loongarch32 适配（rev2 真板波特率） |
| 8660fb1 | sw/boot：mini bootloader（"PMON 阶段"替代） |
| 2d340ab → 1ed9c07 | sw/linux：Linux 5.14 双变体 + DMW 512MB 段修复 + UART 100MHz |
| a630001 | sw/linux：补丁 0008 cache 几何匹配本核 64sets×64B×2way（config=0xfe2914d3）+ waybit 上游 bug 修复 |
| 5c0dac0 | RTL：PRELD 译码为合法 nop（spec 合规提示指令，修 advance n1）；CACOP 保持特权（裁决：站手册 spec，lab19 n52 为 NEMU 怪癖测试非 CPU bug） |

> **译码语义裁决记录**（func_regress/LAB19_ADEF_ANALYSIS.md）：本地回归曾报 lab19 n52 死锁，根因查明为 chiplab 测试语义冲突——lab19 n52 按 NEMU 怪癖（用户态 cacop 不报 IPE）编写，advance n6 按手册（报 IPE）编写；裁决站手册，CPU 行为 spec 正确。同法正名：n7 ECFG 掩码（NOP 按手册可写，quirk 在参考方）、n5 未编译、ADEM 未实现（基座既有，未来启用 n5 需补）。func_lab9（计分套件）修复后复验 58/58 全绿。

产物位置：`sw/boot/`（boot.elf/boot.bin）、`sw/ucore/out/`（ucore.bin 760KB，含 sh/ls 的 sfs initrd）、`sw/linux/out/{verilator-flow,board-16m}/`（vmlinux.bin + start.bin + rootfs.cpio.gz）。
本地 func 回归资产：`/mnt/agents/output/work/func_regress/`（xpm_models.v、nop_difftest_probe.v、setup_env.sh、run_func.sh、SUMMARY.md）。

## 1. 地址与参数总表（背下来）

| 项 | 值 | 出处 |
|---|---|---|
| 复位入口 / bootloader | 0x1C000000 | chiplab SoC |
| 下一阶段镜像暂存区 | 0x1C400000（bootloader ELF loader 从此搬） | sw/boot/boot.h |
| fw_arg 块 | 0x1CFF0000（DDR 顶 64KB，RESERVED） | sw/boot |
| DDR 窗 | 0x1C000000 起 16MB（最小 SoC） | chiplab |
| UART16550 | 0x1FE001E0，PCLK=sys_clk=**100MHz**，115200=**DLL 0x36 + DL3 0x40**（verilator 仿真用 divisor=1 宏） | soc_top.v / uart_regs.v |
| CONFREG | 0x1FAF0000（计时器 +0xE000） | chiplab |
| ucore 链接/入口 | 虚 0xbc000000 = 物理 0x1C000000（DMWIN0） | sw/ucore |
| Linux board-16m 加载 | 物理 0x1C300000（虚 0xbc300000），entry 见 out README | sw/linux |
| Linux verilator-flow | 物理 0x00300000（虚 0xa0300000，RAM 0 起 128MB 流程） | sw/linux |
| 稳定计数器 | 105MHz = CPU 时钟（timer 周期 1,050,000=100Hz） | 本核 |
| TLB | 16 项全相联（PRCFG3=0xf1） | 本核 |
| Cache | I/D 各 64sets×64B×2way=8KB（**内核补丁 0008 已匹配**） | MyCPUConfig.scala |

## 2. 启动拓扑

```
[JTAG-AXI 灌镜像]                    [串口 115200 8N1]
      │                                    │
bootloader @0x1C000000 ──banner──► 终端
      │ ELF loader（暂存区 0x1C400000 → 链接地址）
      ├─► ucore（DA 物理入口 0x1C000000，trampoline 自切 PG）
      └─► Linux（DMW0=0xa0000011 / DMW1=0x80000001，CRMD PG=1 跳 kernel_entry，
               a0=2 / a1=argv "console=ttyS0,115200 rdinit=/init loglevel=8" / a2=bootparam）
               └─ initramfs 内嵌 → /init → /bin/sh → 敲 ls（内存盘=initramfs 根文件系统）
```

两条验收链：**链 A**=bootloader→ucore（保 10 分）；**链 B**=bootloader 或 linux start.bin→Linux→ls（冲 20 分）。bit/sys_test 最终只放一个 bit，按"能演示的最高里程碑"选择。

## 3. 上板 Step-by-Step

### 第 0 步（首位风险，先于一切）：Vivado 重跑实现验证 WNS
- 新网表（aba0eea，123,447 行）在沙箱**无法验证时序**（无 Vivado）；CI 被赛事 deadline_guard 关闭。
- 用比赛工程对 t26-final 的 src/mycpu 重跑综合+实现：确认 setup/hold WNS 均 ≥0 @105MHz。
- 改动性质是常量表/译码追加（译码器 65→71 条），逻辑增量小，但**布局轮盘不可预测**——若 WNS 变负，处置：先多种子（≥4）重实现；仍负则评估回退 PRCFG/IOCSR 到更简实现（如 IOCSR 改译码为非法指令之外的 nop 化）。
- func 回归：本地 verilator 全流程资产在 /mnt/agents/output/work/func_regress/（setup_env.sh 一键重建），结果见 SUMMARY.md。

### 第 1 步：空转链路验证（半天）
- 用 chiplab 自带例程（不动我们的 RTL）生成 bit → 烧板 → 串口看到预期输出。验证：bit 流程/JTAG 灌入/串口终端三件事。

### 第 2 步：bootloader 上板（链 A 起点）
- 灌 boot.bin @0x1C000000 → 上电 → 终端应见 banner。
- **乱码第一排查**：波特率。确认 sys_clk=100MHz（赛事 Clock Wizard 固定），若仍乱码用示波器/调波特率试 115200 上下档位。
- 无输出第二排查：复位入口是否 0x1C000000、JTAG 写入校验（读回比对）。

### 第 3 步：ucore（链 A 收账）
- JTAG 灌 ucore.bin @0x1C400000（bootloader 搬运）或直接灌 @0x1C000000（PMON 式，trampoline 幂等两种拓扑都支持）。
- 预期：ucore boot log → shell（sh/ls/cat 在 sfs initrd 内）。
- 风险点：定时器周期按 105MHz（若决赛改频需同步改 sw/ucore/kern/driver/clock.c 并重编）；UART RX 中断在 SoC 上接地，输入靠时钟中断轮询（已适配）。

### 第 4 步：Linux（链 B）
- 用 board-16m 变体：灌 vmlinux.bin @0x1C300000 + start.bin @0x1C000000（或经 bootloader fw_arg 协议跳转）。
- 预期：内核 log（loglevel=8）→ initramfs 挂载 → /bin/sh → `ls /` 列出内存盘。
- 风险排查顺序：①无 log→串口/入口地址；②早期 hang→TLB（DMW 512MB 段补丁 0003 已修，TLBR 走 DA）；③时钟异常→time.h 105MHz 补丁；④cache 相关灵异→补丁 0008 几何；⑤内存错误→DTS memory=0x1c000000/16MB（补丁 0004）。

### 第 5 步：里程碑封账
- 每链跑通后：录制演示流程文档（show/ 素材）、归档 bit 到 bit/sys_test/（含 README 说明 bin 配套）、git tag 冻结。

## 4. 已知风险矩阵（按概率×影响排序）

| # | 风险 | 状态 | 上板盯法 |
|---|---|---|---|
| 1 | WNS@105MHz 未验证（新网表） | **开** | 第 0 步 Vivado 重实现 |
| 2 | func 回归（本地 verilator） | ✅ lab9 58/58 复验全绿（5c0dac0）；lab19/advance 语义冲突已裁决（非 CPU bug） | 无需动作 |
| 3 | UART 波特率（DL3 小数分频行为） | 已按 100MHz 算 DLL=54/DL3=64 | 乱码先查此项 |
| 4 | Linux TLB 高压力边界（16 项全相联） | 未压测 | kernel panic 带 tlb 字样→TLB |
| 5 | 内核 cache 维护正确性（补丁 0008 后） | 静态核验 | 灵异执行错→cache |
| 6 | timer/udelay 失真（105MHz 假设） | 三处补丁已统一 | 延时明显不对→查频率 |
| 7 | DDR 实际容量（按 16MB 窗假设） | 未探测 | 越窗挂死→改 MEM_SIZE |
| 8 | 内核裁剪版驱动缺失（NET/VT 关） | 已知取舍 | 演示只需串口+sh |

## 5. 复现索引

- RTL 改动明细：src/vivado_cannot/LINUX_SUPPORT.md
- bootloader：sw/boot/README.md（fw_arg/BPI 协议全文）
- ucore：sw/ucore/README.md + PROVENANCE.md（上游 commit + 改动清单）
- Linux：sw/linux/README.md（补丁 0001-0008 清单、双变体表、`build.sh all` 一键复现）
- 侦察依据：/mnt/agents/output/research/final_recon_{toolchain,cpucfg_chiplab}.md
- func 回归环境：/mnt/agents/output/work/func_regress/
