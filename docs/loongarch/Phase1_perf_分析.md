# Phase-1 第一次 perf 构建分析（200MHz）

> 构建：2026-08-18 02:41~03:55，网表 = discrete-o3 Phase-1（round-11 基线 + 提交链
> CM1/邮箱/CM2），隔离 worktree `wt-discrete-perf`，团队工作树零改动。
> 报告源：`analysis_p1/`（cpu_clk_top100 / level_dist / high_fanout）。

## 1. 总账：+0.907ns

| | 基线（round-11b, 8/17 23:38） | Phase-1 | Δ |
|---|---|---|---|
| Setup WNS | **-3.810** | **-2.903** | **+0.907** |
| TNS | — | -29687.756 | — |
| 违例端点 | ~29859 | 27720 / 47273 | -7% |
| Hold WHS | +0.049 | +0.051 | ✓ |

头号路径级数：15 级 → **13 级**；最坏 2000 条违例路径中 11~13 级的仍有 365 条
（11 级 251 / 12 级 82 / 13 级 32），**6 级以下的浅路径 472 条**（纯布线/扇出问题）。

## 2. 阶段 1 的验证：ROB pop 锥消失

| 起点分类（top-100 违例） | 基线（旧报告） | Phase-1 |
|---|---|---|
| ROB popPtr 锥 | **88 条** | **2 条**（popPtr_reg[4]_rep、occupancy_reg[5] 残余） |
| FetchBuffer/译码/派发簇 | — | **~90 条**（新浮现，见 §3） |
| MULDIV DSP 级联 | — | **48 条**（同一条物理路径的 48 个 bit） |
| axiBuffer | — | 1 条 |

删除 fwdCands + 邮箱寄存的预期收益完全兑现；新头名正是 round-11 的
specReadPop 结构把 FetchBuffer 弹出负载选择链跨模块连起来形成的。

## 3. 头号违例：FB 弹出负载选择链（~90 条，-2.903）

```
RENAME_to_DISPATCH_DECODE_PACKET_0_payload_except_valid_reg (RENAME 寄存器)
→ IQ 入队 LUT（MulDiv/IntIssueQueue doRegWrite 比较）
→ freeList 占用计数器（fo=479/1549 大扇出网！）
→ ID_arbitration_isFiring（组合）
→ popCount（组合优先 mux）
→ FetchBuffer specReads 弹出负载 mux（io_pop_2_payload_pc/inst/except/predInfo）
→ 弹出负载寄存器 D
```

13 级，逻辑 1.744ns（22%）/ 布线 6.126ns（78%）。根因：
`MultiPortFIFOVecOutReg`（`MultiPortFIFOVec.scala` L137-148）的 pop 负载 mux 用
**同拍组合 popCount** 选择（`specReads(popCount + i)`），而 popCount 的生成链
（ID 仲裁 firing ← freeList 占用 ← RENAME 有效性）横跨四个模块。

**修复（round-12 #1，与团队 ROB FIFO 的既有解法同构）**：把 pop 侧完全寄存化——
`popCountReg = RegNext(popCount)`，popPtr 按 popCountReg 前进、负载 mux 用
popCountReg 选择、push 折叠条件同步改 popCountReg 时序（照抄
`MultiPortFIFOSyncImpl` 的 fresh 旁路模式）。效果：跨模块链终止于 popCountReg
寄存器，负载 mux 只剩"寄存读 + 3~4 级 mux"，两段均 ≤7 级。语义代价 0（OutReg
本就晚 1 拍，寄存器对齐后协议不变），仅 FB 空满语义按寄存指针重算。

## 4. 次号：MULDIV DSP 级联（48 条，-2.690）

`MULDIV_EXE_MulDivExecutePlugin_multiplier/U0/...DSP48E1[0].CLK → DSP48E1[1].PCIN[0..47]`：
32×32 乘法器两个 DSP48 级联，无中间寄存器（RAW 级联），布线横跨 die。
**修复（round-12 #2）**：物理约束（MULDIV_EXE 区域 pblock / DSP RLOC 邻接）
或改乘法器为两级 DSP 流水（中间插寄存器，multiplyLatency=2 预算已允许）。
一条修复清 48 条路径。

## 5. 残余小项

- ROB 残余 2 条（popPtr_reg[4]_rep -2.728、occupancy_reg[5] -2.647）：popPtr
  复制网与占用计数；MAX_FANOUT/复制即消。
- axiBuffer 1 条：FSM 输出寄存（round-4 #3 后半）。
- 472 条 ≤5 级浅违例：纯布线主导，等结构性修复后再看分布决定是否上 pblock。

## 6. 更新后的阶段排序（数据驱动）

| 优先级 | 项 | 预期收益 | 性质 |
|---|---|---|---|
| 1 | **FB 弹出负载寄存化**（round-12 #1） | 消 ~90 条、WNS ≈ -1.5~-2.5 | 结构（有现成模板） |
| 2 | **MULDIV DSP 级联修复**（round-12 #2） | 消 48 条（1 条物理路径） | 物理/结构 |
| 3 | ROB popPtr 复制 + axiBuffer | 消 3 条 | 小修 |
| 4 | 原阶段 2（IQ 单写者/胞元化） | 尚未浮现（被 FB 链掩盖），round-12 后再测 | 结构 |
| 5 | 原阶段 3（读进胞元/写引擎/容量） | IPC 补偿，时序达标后启动 | 性能 |

每次修复单独一轮 regen + 58/58 + perf，保持归因干净。
