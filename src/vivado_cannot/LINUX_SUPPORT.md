# Linux 启动支持改动说明（2026-final）

本次改动为 LA32R 乱序核补齐 Linux（赛事 5.14 内核 la32r-Linux）启动所必需的
配置寄存器与 IOCSR 指令。所有 RTL 改动均标注注释 `// 2026-final: Linux boot support`。

依据：
- 《龙芯架构参考手册 卷一：基础架构》r1p03 表 2-2（CPUCFG）、7.4.13~15（PRCFG1/2/3）
- la32r-Linux 5.14 `arch/loongarch/kernel/cpu-probe.c`（PRID 公司域 ≠0x14 触发 BUG_ON；
  启动早期无条件执行 iocsr 读；读 PRCFG1/PRCFG3 初始化 kscratch_mask 与 TLB 几何）
- chiplab `nscscc2026` 分支 `software/examples/nscscc_perf/start.S`：仅读 CPUCFG
  word 0x10（及条件读 0x11/0x12/0x13）；`software/examples/func/func_src/init.S`
  不使用 cpucfg/iocsr。因此 word 0x10~0x14（cache 几何）必须保持返回 0，
  perf start.S 依 bit0=0 跳过 cacop 初始化（与原桩行为一致，不影响 perf 计分）。

## 改动明细

### 1. CPUCFG 常量表（src/pipeline/exe/ALU.scala）
原桩 `is(CPUCFG)` 恒返回 0。现按 rj（字号，经 src1 传入）返回常量：

| 字号 | 值 | 含义 |
|---|---|---|
| 0x0 | 0x00144200 | PRID：公司域 0x14 + LOONGSON32(0x42)，5.14 内核 BUG_ON 必需 |
| 0x1 | 0x0001f1fc | ARCH=0(LA32R) \| PGMMU=1 \| IOCSR=1；PALEN=VALEN=31（位数-1）；UAL=0（本核非对齐访存产生 ALE） |
| 0x2 | 0x00004000 | LLFTP(bit14)：有恒定频率定时器（Timer64Plugin 每拍 +1） |
| 0x4 | 0x06422c40 | CC_FREQ=105000000：稳定计数器 = 105MHz CPU 时钟 |
| 0x5 | 0x00010001 | CC_MUL=1 / CC_DIV=1 |
| 其他（含 0x10~0x14） | 0 | 未定义/cache 几何保持 0（见上"依据"） |

### 2. CSR PRCFG1/2/3 只读常量
- `src/constants/LoongArch.scala`：CSRAddress 增加 PRCFG1=0x21 / PRCFG2=0x22 / PRCFG3=0x23
- `src/pipeline/privilege/MMUPlugin.scala`：注册只读映射
  - PRCFG1 = 0x000003f4：SAVENum=4（SAVE0~3）| TimerBits=63（64 位定时器-1）| VSMax=0（ECFG.VS 未实现）
  - PRCFG2 = 0x00001000：仅上报 4KB 页（bit12）
  - PRCFG3 = 0x000000f1：TLBType=1（仅全相联 MTLB）| MTLBEntries=15（本核 TLB 16 项，编码为项数-1，取自 `tlbConfig.numEntries`）

### 3. CSR ASID.ASIDBITS
现状即为 0xa（MMuPlugin `ASID_ASIDBITS = B(0xa, ...)`），无需改动。

### 4. IOCSR 指令（iocsrrd.b/h/w、iocsrwr.b/h/w）
- `src/constants/LoongArch.scala`：新增 6 条编码（0x06480000/0x06480400/0x06480800/0x06481000/0x06481400/0x06481800，bits[14:10] 为变体号）
- `src/constants/enum/ALUOpType.scala`：新增 `IOCSR` 操作
- `src/pipeline/decode/DecoderArrayPlugin.scala`：iocsrrd 走 ALU 通路恒写 0；iocsrwr 读 rj/rd、写忽略、rd 写回旧值（0）。不产生异常；已加入 privInst 列表，用户态执行产生 IPE（特权级执行）
- `src/pipeline/exe/ALU.scala`：`is(IOCSR)` 返回 0

## Runbook 风险项（按优先级）

1. **WNS / 105MHz 时序收敛未验证（首位）**：本沙箱无 Vivado，新网表在 105MHz
   （perf_clock.json）下的时序收敛必须在 Vivado 实现流程重跑确认（WNS 不允许为负）。
   本次改动为译码/常量mux 级逻辑，理论上对关键路径影响极小，但以上板前的
   Vivado 时序报告为准。赛事 CI 因提交截止（deadline_guard，README 第4条）
   不再运行，时序验证须走赛事方决赛提交通道。
2. 功能回归：本地以 chiplab（nscscc2026）Verilator 流程跑 func 测试验证
   （结果见本节末尾追加记录）。

## 网表重生成与 diff 结论
- 按 COMPILE.md 执行 `runMain NOP.Main`（sbt-launch 1.9.9 + JDK17），产物
  `build/mycpu_top.v`（123447 行）替换 `src/mycpu/mycpu_top.v`（原 122986 行）。
- 对信号名做行号后缀归一化后的多重集 diff：**旧网表每一行在新网表中均存在
  （零功能性删除）**；新增逻辑仅限：CPUCFG 常量表（ALU）、PRCFG CSR 读译码
  （0x21/0x22/0x23 三个 case）、IOCSR 译码条目与 IPE 条件（3 个译码器 ×6 条）、
  `ALUOpType_IOCSR` localparam 及仿真字符串表。其余差异为 SpinalHDL 信号命名
  行号后缀漂移（声明顺序/命名噪声）。
- core_top.v 为手工 wrapper，未改动。
