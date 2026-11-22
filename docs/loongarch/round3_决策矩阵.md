# Round 2 结果 → Round 3 决策矩阵

第 2 轮 = P2-P7 全量网表（含复位补丁）。参考点：第 1 轮（P1）WNS -3.842，
唯一 setup 违例 = 15 级提交环；复位 recovery -2.708（补丁已修，第 2 轮应消失）。

## 第 2 轮结果分档 → 动作

### A. WNS ∈ [-0.5, 0)：差最后一脚
1. 按报告取 Top-20 违例路径，逐条做:MAX_FANOUT/复制/小 mux 树化。
2. 复位补丁若未完全消除 recovery 违例,调 max_fanout 值(200→100)。
3. 候选:phys_opt -force_replication_on_nets 指名列出的网。

### B. WNS ∈ [-1.5, -0.5)：环路残余 + 布线
1. 若最差路径仍是 state→state 环(>10 级):P4b 前递比较 3 位化+
   高两位环外判定;再把 uncachedMask 从 FSM 提前到寄存输出。
2. 若最差路径是 MEM 链(TLB/DCache/唤醒):clrBusy 提前寄存
   (注意 load-use +1 拍的 IPC 代价)或物理地址 mux 前移。
3. 布线占比>80% 的路径:FF 驱动 + MAX_FANOUT 复制。

### C. WNS ∈ [-2.5, -1.5)：结构性
1. retireWidth 3→2(一行改动,预案 local_ci/retire2.patch.note):
   环路 → 约 6-7 级,commit 带宽 2/拍。代价 IPC 上限降,需跑
   perf 分数对比(200MHz×IPC2 < 200MHz×IPC3,但 > 收敛不了)。
2. MEM 链分拍:DCache tag 比较/MEM2 异常汇总挪 WB。

### D. WNS < -2.5：环路没拆掉
1. 重查 P2 的投机读是否被综合器还原(检查 specReads 在网表中的
   6 路并行结构是否保留)。
2. popCount 完全寄存化拆环(方案:fire 决策一拍前移到寄存器,
   pop 接口整体后移一拍,CommitPlugin fire 动作随 payload 对齐)。

## 验证流程(每次 RTL 变更)
regen_and_patch.sh → xsim 58 点 → 提交 → run_gen_perf.sh(200MHz)
