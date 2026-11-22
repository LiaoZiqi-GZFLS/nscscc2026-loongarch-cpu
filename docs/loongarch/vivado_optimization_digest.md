# 《AMD FPGA 设计优化宝典（高亚军）》龙芯杯可用性提取报告

> 夜神骇客（T2026143250012561）· 2026-08-13
> 赛情锚点：xc7a200t（7 系列 28nm）、Vivado 2023.2、目标 105MHz（T=9.52ns）、当前 WNS 余量仅 +0.035ns、**官方 CI 流程禁改 tcl/xdc/时钟**、候选 A=32K PHT 读路径、候选 B=4-way D$ tag 扇出。
> 全书 10 章、65 条设计规则。本报告只提取**与我们赛情有映射关系**的内容，并标注每条的使用边界。

---

## 0. 使用边界（先读这条，决定每条建议能不能上 CI）

| 手段层级 | 例子 | 能否进官方 CI |
|---|---|---|
| **RTL 内嵌综合属性**（随 mycpu_top.v 走） | `(* max_fanout=… *)`、`(* keep/dont_touch *)`、`(* async_reg *)`、复位/流水风格 | ✅ 合法，属于我们的代码 |
| **RTL 结构改写** | 插流水、FU 口分区、复位树、驱动由 LUT 改 FF | ✅ 合法，但要过 func 回归 + A/B |
| 流程策略/tcl/xdc | phys_opt_design -directive、综合策略、约束文件 | ❌ 官方禁改，**仅本地实验用**，验证结论须翻译回 RTL 层落地 |

**核心推论**：书里 9.2/9.3/10.2/10.3 的流程与约束手段对我们都是"本地诊断镜"，最终能提交的只有 **RTL 层等价物**。

---

## 1. 三条全书级经验法则 → 我们的数字

**① 逻辑级数法则（ch1）**：一级"LUT+走线"≈0.5ns（7 系列适用）。
- 105MHz 周期 9.52ns → 理论上限 ≈19 级；扣掉时钟偏移/建立时间，**实用预算 ~15 级**。
- 行动：本地实现后看 `report_timing_summary` 里失败路径的 **Logic Levels** 列；>15 级且 WNS 为负 → 就是逻辑级数问题，解法只有插流水或拆逻辑（对应我们 P0 资产的"FU 口分区"——本质就是把唤醒-选择逻辑从大扇入 MUX 拆小）。

**② 资源 80% 红线（ch1，report_qor_assessment/failfast）**：BRAM、DSP 利用率不能超过 80%（或三者均值 <80%）。
- xc7a200t 家底：365 个 BRAM36、740 个 DSP48E1、约 33.6K LUT...（以 report 为准）。候选 B 的 D$ 翻倍 + 候选 A 的 32K PHT 都吃 BRAM，本地跑完**必须盘点 BRAM 总量**。

**③ 控制集阈值（ch4 规则 5）**：控制集个数占比 <7.5% 可接受，7.5-15% 建议减，>15% 必须减。
- 我们的网表是 SpinalHDL 生成、**全异步低有效复位 aresetn**（实测：MyCPUCore 单 always 块 6400+ 寄存器声明，时序块均为 `posedge aclk or negedge aresetn`）。控制集少是好事，但见 §3 的吸收问题。

---

## 2. 对两个候选分支的定向风险检查（G0 定版必查）

### 候选 A（t26-bpu-h7）：32K PHT 读路径
- **BRAM 输出寄存器（ch6 规则 2/17）**：32K×2bit PHT = 64Kbit ≈ 2 个 BRAM36。书中实测：BRAM 不用自带输出寄存器时 clk→out 达 **1.8ns**；用了（DOA_REG=1）显著更低。**检查：PHT 的 BRAM 是否带输出寄存器**——若没带且 WNS 卡在 PHT 读路径，给 PHT 读加一拍输出寄存是最直接的修法（代价：预测延迟 +1cyc，需重跑 RTL A/B 确认精度损失可接受）。
- **GHR 移位寄存器（ch5）**：7bit GHR 会被推断为 SRL 或 FF 链，无大碍；注意综合策略 Flow_AlternateRoutability 会把 shreg_min_size 提到 10——官方流程策略未知，若 GHR 走了 SRL 且出现在关键路径，可在 RTL 加 `(* shreg_extract="no" *)` 强制 FF。
- **快照对齐修复**改变了 PHT 读索引的驱动逻辑，综合后重点看它的扇出。

### 候选 B（t26-dcache-4way）：4-way tag 比较
- 4 路 tag 并行比较 + `OHToUInt` + `MuxOH(hits, dataRAMs…)`：数据选择从 2 选 1 变 4 选 1，**逻辑级数 +1~2 级、扇出翻倍**。若 WNS 卡在 D$ 命中路径：
  - 书中 ch9 规则 2 的 RTL 版：**让高扇出网线的驱动是 FF 而非 LUT**——检查 tag 比较结果是否打拍；
  - 命中路径的 info RAM 回写已被我们删除（RR 替换），这恰好符合书中"减少控制信号/写口竞争"的方向，是加分项。

---

## 3. 复位与控制集（实测网表后的判断）

- 我们的网表全部是**异步复位**（`negedge aresetn`）。书中规则 4/6/规则 2(ch6)/规则 4(ch7) 共同指向一个风险：**异步复位的寄存器无法被吸收进 BRAM 输出寄存器 / DSP48E1 / SRL**。
- 当前没炸是因为 cache/PHT 的 RAM 由 SpinalHDL 黑盒/xpm 推断、乘法器走 xci IP。但**频率冲刺时**，如果想把某个关键 RAM 输出寄存器、或乘法器流水级"吸入"硬核，就必须把那部分寄存器改成**同步复位或无复位**（SpinalHDL 里可用局部 `ClockDomain` 配同步复位，或干脆对纯数据通路寄存器去复位——书中规则 9：只起上电复位作用的复位信号应移除，用初始值代替）。
- 这同时降低全局 aresetn 的扇出（ch9：全局复位改**复位树**，ch4 规则 8），为物理实现腾余量。**列为 P0 频率冲刺资产的候选动作，不动当前候选分支。**

## 4. DSP / 乘加（ch7）
- 规则 1：用 DSP48E1 乘法器必须确保 **MREG 被打上**（三级流水：AREG/BREG→MREG→PREG）。我们的 multiplier 走 xci IP——本地打开 IP 配置确认流水级数；若 MUL 在 WNS 失败路径上，先查这里。
- 规则 8：大位宽加法器高频下可用 DSP48 实现。LA32R 的地址生成（AGU 加法）若在关键路径，可考虑映射 DSP（740 个 DSP 我们用量极小，资源富余）。

## 5. 本地诊断命令清单（run_gen.sh 跑完 gen_perf 后，在 route 后的 dcp 上执行）

```tcl
# ① 时序全貌 + 逻辑级数（§1① 的判据）
report_timing_summary -max_paths 20 -input_pins -file ts.txt
# ② 高扇出网线（带时序权重，ch9 规则 1/2；重点看 LUT 驱动的）
report_high_fanout_nets -timing -load_types -max_nets 25 -file hfn.txt
# ③ 控制集（§1③ 阈值判读）
report_control_sets -verbose -file cs.txt
# ④ 拥塞与复杂度（ch10：Rent≥0.65 且实例>15k = 互联过重——重点看 BypassNetwork/AXI Crossbar）
report_design_analysis -congestion -complexity -file cong.txt
# ⑤ Vivado 自动 QoR 建议（2023.2 支持；结论只能翻译回 RTL 层用）
report_qor_suggestions -file qor.txt
# ⑥ 资源红线快速评估（§1②）
report_qor_assessment -file qoa.txt
```

判读顺序：②的 LUT 驱动高扇出 → 改 FF 驱动（RTL）；④的拥塞模块 → 定位到具体插件；⑤的建议凡属约束类一律只做本地对照实验。

## 6. 章节价值地图（复读到章级）

| 章 | 价值 | 为什么 |
|---|---|---|
| ch3 组合逻辑 | ★★★ | LUT6 双输出/LUT 整合、case 互斥→平行 MUX、if 链→优先级结构——写/改 RTL 时预判综合结果的依据 |
| ch4 触发器 | ★★★ | 控制集阈值、复位树、"需要复位与不需要复位的信号分开写"（我们的 SpinalHDL 网表可借局部 ClockDomain 实现） |
| ch6 存储器 | ★★★ | BRAM 输出寄存器、分布式 RAM 输出打拍（我们的 sRAT/freeList/ROB 是 LUTRAM——高频下输出加一拍）、Block→Reg→Block |
| ch9 扇出 | ★★★ | report_high_fanout_nets 工作流 + "LUT 驱动改 FF 驱动" + MAX_FANOUT 的 RTL 属性版 |
| ch7 乘加 | ★★ | multiplier IP 流水检查、DSP 实现大加法器 |
| ch8 状态机 | ★★ | D$ 的 4 个 FSM 状态数 4-8：按规则 5，≤5 用二进制、5-50 用独热——检查 fsm_extraction 是否 auto 生效 |
| ch10 布线拥塞 | ★★ | 拥塞报告判读（我们设计规模 ~10 万 LUT 级，拥塞大概率不致命，备查） |
| ch2 时钟网络 | ★ | 平台 PLL/时钟全锁死，仅 2.4 节"门控时钟检测"可备查 |
| ch1/ch5 | ★ | 背景与 SRL 细节 |

## 7. 落地优先级（并入决赛路线图）

| 序 | 动作 | 时机 |
|---|---|---|
| 1 | G0 本地实现后跑 §5 六条诊断，按 §2 清单核对 A/B 各自风险点 | **本次本地跑 CI 时同步做** |
| 2 | 若 WNS 为负：PHT 输出寄存器（A）/ tag 路径打拍（B）为首选 RTL 修法 | 仅当失败时 |
| 3 | 复位风格改造（数据通路去复位/局部同步复位）+ 复位树 | 赛后/频率冲刺资产 |
| 4 | §3-§5 写成答辩"物理实现"小节：0.5ns 法则、80% 红线、控制集阈值都是现成的量化叙事 | 答辩材料 |

> 提醒：本书示例语言是 VHDL，但所有结构结论（LUT6/BRAM/DSP/控制集/扇出）对我们 Verilog 网表完全同构适用。
