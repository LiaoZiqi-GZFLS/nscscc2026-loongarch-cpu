# Round 4 候选（等 round-3 布线数据确认后实施）

Round-3 = P8+P12（提交前递折叠 + 译码 MuxOH 修复）。构建中（run_gen_perf.sh，
200MHz）。round-3 布线完成后用 `local_ci/analyze_route.tcl` 取 top60 路径 +
逻辑级数分布，按数据挑目标。

## 已知 round-2（P2-P7）违例速览（WNS -4.095，routed）

| 路径 | 级数 | round-3 后预期 |
|---|---|---|
| decode ID_to_RENAME_DECODE_PACKET_0_doRegWrite | 15 | P12 已修（MuxOH 65:1≈3级） |
| BTB valid CLR recovery | -2.829 | 未动 |
| ROB pushPtr 前递锥 | 15 | P8 部分影响（pushOff 比较仍在） |
| MEM 地址链（RRD 32位加 + TLB CAM） | 15（CARRY4×8） | 未动 |
| FetchBuffer popPtr→PHT | 13 | 未动 |
| axiBuffer FSM | 11-12 | 未动 |
| IQ rRegs valid（TLB快照→唤醒） | 10 | 未动 |
| 复位 recovery | -0.112 | max_fanout=200 补丁已基本消除 |

## 候选清单（低风险优先，逐个 regen+58/58+build）

1. **commit predUpdate 一拍寄存**（GlobalPredictorBTBPlugin + ReturnAddressStackPlugin）：
   BTB valid(index)/RAM write/GHR 恢复整体延一拍。正确性靠 mispredict recovery 兜底；
   代价：恢复后 1-2 拍用旧 GHR（多一次误预测）。消掉 commit→BTB valid/PHT 长链。
2. **MEM 地址加法分拍**（MemExecutePlugin.RRD）：RRD 只算低 16 位+进位，
   MEMADDR 算高 16 位（进位来自 RRD 寄存器）。MEMADDR 的 TLB CAM 依赖高 16 位，
   需评估 MEMADDR 深度（高16加 4 级 + CAM ~8 级 ≈ 12 级）——**不如改为
   RRD 并行双加 carry-select**：低 13 位算出进位 c13，高 19 位 VPPN 用
   c13=0/1 双份并行加 + 选择（5+1 级），RRD≈8 级，MEMADDR 保持纯 CAM(~8)。
   再评估 P6 的三级 PRF 读 mux 是否可前置。
3. **axiBuffer FSM 输出寄存**：outaw/outw payload 已在 waitRead 后经 regEntry 寄存；
   深的是 FSM 条件链（ready 与门 → 下一状态 mux）。改法：FSM 下一状态与输出
   全部寄存一拍（牺牲 1 拍 handshake 延迟）——uncached 延迟敏感，需 func 仿真确认
   节奏不回退。
4. **BTB 恢复 valid 清零一拍寄存**（与 1 同源，同拍做）。
5. 复位 max_fanout 200→100：若 round-3 recovery 仍 > -0.2ns。

## 流程

```
regen_and_patch.sh (Git Bash!) → run_xsim_p1.bat(自动切 RUN_FUNC_TEST, 58/58)
→ git 提交 → soc_config 切 RUN_PERF_TEST → run_gen_perf.sh (Git Bash)
```

注意：run_gen_perf.sh 的 chiplab reset 会删生成 IP 的 sim 文件
(vio_0_sim_netlist.v 等)，构建完成后会重新生成；run_xsim 前确认存在。
