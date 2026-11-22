# 200MHz (perf) 逻辑深度统计

- 数据来源: `perf_timing_summary.rpt`（最近一次跑完的 200MHz 布线结果，2026-08-16 21:55，Vivado 2023.2，xc7a200t-fbg676 -2）
- 说明: 2026-08-17 09:00 起另有一轮 `route_design -directive Explore` 正在后台运行，本统计基于上一次已完成的布线；两轮网表/约束相同，逻辑级数不变。
- 约束: `cpu_clk = 5.000 ns (200MHz)`，PLL CLKOUT0，BUFG 扇出 23015。

## 1. 总览

| 项目 | 数值 |
|---|---|
| Setup WNS | **-3.842 ns** |
| Setup TNS | **-46073.301 ns** |
| Setup 违例端点 | **29859 / 84733** |
| Hold WHS | -0.037 ns（1 个端点） |
| cpu_clk 域内 Setup | WNS -3.842 ns，TNS -41471 ns，**26876 / 46002 端点违例（58.4%）** |
| cpu_clk 异步复位(recovery) | WNS **-2.708 ns**，TNS -4602 ns，**2983 / 6984 端点违例** |

结论：**不是一两条路径的问题，而是 cpu_clk 域近六成端点整体性违例**，200MHz 目前差得很远（最坏路径要求 5.0ns，实际 8.742ns）。

## 2. 各时钟组最坏路径的逻辑级数（Setup，Slow Corner）

| 路径组 | Slack (ns) | 逻辑级数 | 组成 | 数据路径延迟 (ns) | 逻辑占比 / 布线占比 |
|---|---|---|---|---|---|
| **cpu_clk**（ROB pop 路径） | **-3.842** | **15** | LUT2=1 LUT4=2 LUT5=3 LUT6=8 MUXF7=1 | 8.742 | 25.4% / **74.6%** |
| **async_default** cpu_clk（复位 recovery） | **-2.708** | 1 | LUT1=1（fanout 6956） | 7.216 | 7.5% / **92.5%** |
| sys_clk | +0.949 | 7 | LUT2=1 LUT3=1 LUT4=1 LUT5=1 LUT6=3 | 8.660 | 16.7% / 83.3% |
| clk → sys_clk | +4.681 | 5 | LUT3=1 LUT4=1 LUT5=2 LUT6=1 | 5.062 | 22.4% / 77.6% |
| clk | +4.258 | 3 | LUT5=1 LUT6=2 | 5.707 | 12.2% / 87.8% |
| ddr_clk | +2.547 | 1 | LUT2=1 | 1.937 | 30.5% / 69.5% |
| clk_pll_i | +1.260 | 1 | LUT5=1 | 8.539 | 5.7% / 94.3% |
| TCK (debug_hub) | +26.758 | 6 | CARRY4=2 LUT3=1 LUT4=1 LUT5=1 LUT6=1 | 6.250 | 27.3% / 72.7% |

其余时钟组（iserdes/oserdes、mem_refclk 等）最坏 Setup 路径均为 0~1 级，全部 MET。

## 3. 头号关键路径逐级拆解（15 级）

起点: `ROBFIFOPlugin_robInfo/popPtr_reg[0]_replica/C` (SLICE_X83Y70)
终点: `ROBFIFOPlugin_fifoIO_pop_0_payload_state_intResult_reg[5]/D` (SLICE_X103Y68)

| 级 | 单元 | 逻辑延迟 | 网表扇出 | 布线延迟 |
|---|---|---|---|---|
| 0 | FDCE popPtr[0] C→Q | 0.379 | fo=11 | 0.377 |
| 1 | LUT2 `mem_i_63__10` | 0.105 | **fo=155** | **0.696** |
| 2 | LUT6 `mem_i_61__10` | 0.105 | fo=1 | 0.122 |
| 3 | LUT6 `mem_i_30__12` | 0.105 | **fo=114** | 0.461 |
| 4 | MUXF7 `CommitPlugin_regFlush_reg_i_2` | 0.227 | fo=2 | 0.262 |
| 5 | LUT4 `popCountReg[1]_i_6` | 0.252 | fo=1 | 0.468 |
| 6 | LUT5 `popCountReg[1]_i_3` | 0.105 | fo=5 | 0.252 |
| 7 | LUT5 `popCountReg[0]_i_2` | 0.105 | fo=3 | 0.451 |
| 8 | LUT6 `popCountReg[0]_i_1`（产生 popCount[0]） | 0.105 | **fo=59** | 0.547 |
| 9 | LUT4 `badVA[31]_i_6` | 0.105 | **fo=78** | 0.692 |
| 10 | LUT6 `actualTaken_i_26`（比较器） | 0.105 | fo=1 | 0.332 |
| 11 | LUT5 `actualTaken_i_16`（产生 when_ROBFIFOPlugin_l177） | 0.105 | **fo=33** | **0.959** |
| 12 | LUT6 `intResult[5]_i_4` | 0.105 | fo=1 | 0.530 |
| 13 | LUT6 `intResult[5]_i_3` | 0.105 | fo=1 | 0.254 |
| 14 | LUT6 `intResult[5]_i_2` | 0.105 | fo=1 | 0.116 |
| 15 | LUT6 `intResult[5]_i_1` | 0.105 | fo=1 | 0.000 |
| | 合计 | 2.223 | | 6.519 |

要点：
1. 15 级里逻辑延迟只有 2.223ns，**布线延迟 6.519ns 占 74.6%** —— 逻辑深度是诱因，长距离 + 大扇出布线才是大头。
2. 5 条大扇出网（fo=155/114/59/78/33）合计贡献 **3.355ns** 布线延迟。
3. 起点寄存器是 phys_opt 复制出来的 `popPtr_reg[0]_replica`，说明 popPtr 本身扇出已经爆了。

## 4. RTL 对应关系（`chiplab/IP/myCPU/mycpu_top.v`）

整条路径都在 ROB（Reorder Buffer）的 pop 端口逻辑上：

- `module unamed_2`（例化名 `ROBFIFOPlugin_robInfo`），第 176007–180290 行：3 push × 3 pop 的 ROB FIFO（ram 子模块 + 读端口复制 rspReplicas）。
- 第 1–8 级：popPtr → RAM 读端口译码/输出 mux → `CommitPlugin_regFlush`（MUXF7）→ `popCount` 两级 mux 链：
  - `popCount = (!io_pop_0_fire) ? 2'b00 : (!io_pop_1_fire) ? 2'b01 : (!io_pop_2_fire) ? 2'b10 : 2'b11;`（第 180031 行）
  - `popCountReg <= {1'd0, popCount};`（第 180284 行，popCountReg 已寄存，但负载选择用的是组合的 popCount，寄存器版本晚一拍，用不上）
- 第 9–15 级：pop payload 的 mux 树 —— `state_except_payload_badVA` → `state_actualTaken`（比较器）→ `state_intResult[5]` 四级 LUT6 mux。
- 上游还有 `ROBFIFOPlugin_completionQueues_0..7_io_window_0..31_state_*`（8 条完成队列 × 32 窗口，第 7700 行起）做 mux 的数据源，宽度 32，是典型的 SpinalHDL 大选择器结构。

## 5. 第二大违例类：异步复位网络（不是逻辑深度问题）

- `fpga_pll.u_rst_cpu/delay_reg[1]_replica_1/Q` → LUT1 → `mem_rstb`（**fanout=6956**，布线 6.299ns）→ PhysRegFile/TLB 等 FDCE.CLR。
- recovery 违例 -2.708ns，2983 个端点。方法论报警 `LUTAR-1 (LUT drives async reset)` 8 处。
- 逻辑只有 1 级，纯属复位网络长线 + 超大扇出问题。

## 6. 建议（按优先级）

1. **给 ROB pop 负载加一拍寄存器**（最大收益）：把 pop payload（badVA/actualTaken/intResult 等）输出寄存化（SpinalHDL 里给 pop 流加 output register 或改用带 `pipelined()` 的 FIFO），15 级砍成 2 段，每段 ≤8 级。注意 commit 时序要对齐。
2. **提前一拍计算 popCount / regFlush**：让 payload mux 选择用 `popCountReg`（已存在的寄存器），把"popPtr→RAM→popCount→payload"这条串行链拆开。
3. **大扇出网复制**：fo=155/114/78/59/33 的 5 条网用 `MAX_FANOUT` 约束或手动复制驱动；popPtr/popCount 可显式复制（综合器只复制了 popPtr[0]）。
4. **复位网络**：`mem_rstb`(6956) 上 BUFG 或按模块分散同步复位，消除 2983 个 recovery 违例。
5. 修完上述路径后，**当前这轮布线跑完**再跑一次 `report_timing -from cpu_clk -to cpu_clk -max_paths 100` + `report_design_analysis -logic_level_distribution`，拿完整直方图（本报告只有各组第 1 条路径，TNS 表明后面还有大量路径）。

## 7. 附：func 版本对照

- func 版 cpu_clk = 30.556ns (32.7MHz)，Setup WNS +0.978ns（全 MET）；最坏路径 4 级（SpeculativeWakeupHandler → IntIssueQueuePlugin）。
- 即同一份网表在 32.7MHz 下轻松通过、在 200MHz 下 58% 端点违例，瓶颈确认在 ROB pop 等少数几条超深组合链上。
