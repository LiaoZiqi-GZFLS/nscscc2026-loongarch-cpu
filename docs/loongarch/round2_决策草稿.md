# Round 1 之后的预期路径与修复菜单（决策草稿）

基线(旧 CAM 版): phys_opt 估算 WNS -5.470, 布线后 WNS -3.842 / TNS -46.1us。
Round 1 = 纯 ROB 读侧改造(9ec3648), 未含复位补丁(4d14af0 留待 round 2)。

## 预测: round 1 之后剩余的深路径(等实测报告验证)

### A. 提交决策环(最可能的新瓶颈)
状态寄存器读前推一拍(state_reg[N] = batch N 的状态, 在 N-1 拍用
idx[N-1]=popPtr[N-1]+popCount[N-1]+i 计算), 因此存在每拍闭环:
  state Q → completeMask(2级前缀与) → excMask(2-3级) → readyMask(1级)
  → fire(1级) → popCount(2级优先级mux) → idx 加法(2 CARRY4)
  → readState 8:1+4:1(3级) → 同拍前递优先级 mux(1级) → state D
合计约 13-14 级, 但全程是局部信号(state reg/robState bank/指针寄存器
可以集中放置), 逻辑约 1.5ns, 若布线可控在 2ns 内, 5ns 周期可能直接收下。
判据: round1 报告中若有 state_reg → state_reg 的 13+ 级路径且 slack<0,
按下述 A1-A3 逐条砍。

- A1. 4 候选 idx: popCount ∈ {0..3}, 提前并行算 popPtr+0..3+i(4 组 CARRY4),
  再由 popCount 4:1 选择(1级) → idx 路径从 2 级加法+选择变为 1 级选择。省 1 级。
- A2. stateSel 拆分: {complete, except.valid, mispredict}(环上需要的 3 bit)
  与其余 payload 位(intResult/badVA 等)各走独立的 readState mux。
  级数不变, 但环上 mux 宽度 90→3, 布线大幅缩短, 可放开给布线器更多裕量。
- A3. readyMask 化简: completeMask 前缀与可用 carry/进位逻辑压级。

### B. MEM1 TLB 快照 → 发射队列唤醒(旧报告 15 级, 独立锥)
旧路径: MEMORY_ADDRESS_reg →(9级)→ TLB_LOOKUP_SNAPSHOT →(15级)→
IntIssueQueue rRegs valid。clrBusy 比较本体约 4-5 级, 大头在 clrBusy_valid
生成链(执行级完成仲裁)与队列槽写 mux。若 round1 中仍出现, 修法:
- B1. clrBusy_valid 提前一拍寄存(执行级完成信号本来就稳定得早)。
- B2. CompressedQueue 的唤醒写口改成独立寄存器通道。

### C. 复位 recovery(已知, 4d14af0 已修, round2 验证)
### D. 高扇出网(逐条按报告 MAX_FANOUT/复制)

## 验证流程备忘
1. 功能: xsim 58 点(func 套件, 10ms) — round1 未打补丁版已过;
   补丁版在构建结束后用 regen_sim_models.tcl 重建 IP 模型后补跑。
2. 时序: bit.tcl 门 = setup_wns ≥ 0 且 hold_wns ≥ 0(含 async_default recovery)。
3. 提交: 每轮 RTL 变更后 sbt 再生成 + patch_reset_fanout.py + 拷贝 src/mycpu,
   功能仿真通过再跑 perf 构建。
