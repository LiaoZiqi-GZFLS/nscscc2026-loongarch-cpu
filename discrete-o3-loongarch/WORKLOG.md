# discrete-o3 工作日志

> 独立实验文件夹：基于 `T2026143250012561`（8/17 基线，58/58 通过、perf WNS -3.810ns）
> 的 SpinalHDL 源码副本，实施《离散式乱序三发射架构设计》（`docs/设计文档.md`）。
> 本文件夹只含源码 + sbt 工程（0.5MB），与主线完全隔离；改动完成后用 sbt 重新
> elaborate 出 `build/mycpu_top.v`，再拷回主线走 regen + 58/58 + perf 流程。

## 目录

- `src/` — SpinalHDL 源码（原样拷贝 + 阶段 1 修改）
- `docs/设计文档.md` — 架构设计文档（含最终 review 修订）
- `build/` — 生成网表输出（elaborate 后出现）

## 阶段 1：提交链 CM1/CM2 + 邮箱（实施中）

### 已改文件

1. `src/pipeline/core/ROBFIFOPlugin.scala`
   - **删除 fwdCands 全部同拍前递折叠**（specReads 6 路投机读、派发折叠、WB 折叠、
     completePorts 折叠，约 2k LUT）——这是 88/100 条最坏路径的 90bit 锥源头。
   - pop(i).state 改为 `readState(popPtr + i)` 直接寄存读（库内 8:1 + 库间 4:1
     ≈ 4~5 级），**popCount 不再参与 payload 选择**，只驱动指针与邮箱有效标记。
   - WB 随机写口（alu/bru/lsu/complete）保留原样（写侧不在关键路径）。
   - 语义变化：WB(n) 写状态 n+1 可见 → 提交最早 n+1（原 n，同拍前递省的那 1 拍
     被舍掉）；派发前递同理（空 ROB 派发后 1 拍才可提交，occupancy 寄存器本就
     晚 1 拍，无新增缺口）。

2. `src/pipeline/core/CommitPlugin.scala` — 重写 retire 区：
   - **CM1（本拍）**：pure decision。输入全部为寄存器：pop state（robState 寄存读）、
     pop info（RAM 读 + fresh 旁路）、uncachedMask（FSM 状态寄存器）、intPending。
     `c0/c1/blk0/blk1/mp0/uq1/linearRecover → ready → fire → popCount`（≈5~6 级）。
   - **邮箱（CM1→CM2 寄存器边界）**：`mbValid/mbCount/mbFire[2]/mbEntries[2]/
     mbHasExcept/mbLinearRecover` 全部 RegNext。
   - **CM2（下一拍）**：全部退役动作只消费邮箱——ARF 提交、freeList push（经
     arfCommits）、CSR 写、TLB op、cache op、ertn/doWait、commitStore、LL/SC、
     BTB/RAS predUpdate、重定向（jumpInterface）、异常提交、flush。
   - **flush 对齐协议**：CM2 的 `needFlush = mbValid && (mbHasExcept || mispredict0
     || mbLinearRecover0)` 同拍抑制 CM1 的 fire（ready 门控 +`!needFlush`，1 级）。
     保证 flush 拍不 pop → freeList recover 不变式（"recover 周期无 push/pop"）成立：
     分支在 C 拍 pop 进邮箱，C+1 拍 flush（ROB 指针清零、取指/译码 flushIt），
     C+2 拍 regFlush 触发 sRAT/freeList/IQ 恢复，C+2 拍邮箱无效（fire 被抑制）
     → 无 push；C+2 拍 RENAME 已被 flush → 无 pop。✓
   - **uncached FSM**：门控继续用 CM1 视图（pop 前读 `popPorts(0)`），commitStore
     时序与原版一致；intInhibit/hasExcept 的 CM1 视图与邮箱视图（mbHasExcept）分离。
   - 环证明：robState Q → 决策 → popCount → 指针/邮箱 → needFlush → ready，
     环上必经邮箱寄存器，无组合环。

### 时序影响（与设计文档 §0/§7 一致）

- 提交动作整体晚 1 拍（IPC ≈ -1~2%）；误预测重定向晚 1 拍。
- CM1 深度 ≈ 4~5（状态读）+ 3（决策）≈ 7~8 级，全局部窄位；若实测 CM1 违例，
  fallback：决策位拆 3bit 窄读 / CM0 再寄存一拍（文档 §4.1 已列）。
- 头号 15 级路径（popPtr→intResult）现在被邮箱寄存器切成两段。

### 已验证（2026-08-18，本文件夹内完成）

- ✅ `sbt compile` 通过（87 个源文件，无新错误）。
- ✅ `sbt "runMain NOP.Main"` elaborate 通过 → `build/mycpu_top.v`
  （9.14MB / 154,595 行，较基线净减——fwdCands ~2k LUT 已删）。
- ✅ 网表结构抽查：
  - `fwdCands` 出现次数 = 0（90bit 前递锥彻底删除）；
  - 提交邮箱寄存器就位（`CommitPlugin_mbEntries_0/1_state_*` 148+ 信号、
    `mbValid/mbHasExcept/mbLinearRecover` 16 处）；
  - flush 对齐协议连线正确（`CommitPlugin_needFlush` 驱动 ROB `.flush` 端口 +
    regFlush + fetch/decode flushIt）。
- ⚠️ 组合环：elaborate 通过即说明无组合环（SpinalHDL 会在 elaboration 报环）。

### 待验证（需要主线 CI 流程，本文件夹无法独立跑 xsim/Vivado）

1. `sbt "runMain NOP.Main"` elaborate 通过（本文件夹可做，已在跑）。
2. 拷回主线 `src/mycpu/mycpu_top.v` 后：regen + 58/58 功能门。
3. perf 构建（200MHz）：`report_timing -max_paths 100` 确认 pop 锥消失、
   CM1 深度；`report_design_analysis -logic_level_distribution` 确认 ≤10 级。
4. 专项单测（§9 风险 #3）：空 ROB 派发+立即误预测、连续误预测、异常+uncached
   组合——构造 flush 对齐协议用例。

### 未包含在本阶段（文档 §8 阶段 2/3/4）

- SystolicIssueQueue 替换 CompressedQueue（骨架在 `src/pipeline/discrete/`）
- 译码 3 拍化、EXE 提前重定向、读进胞元双总线、写引擎广播合并、容量扩张
- axiBuffer FSM、pblock、复位网拆分（芯片级流程，需主线脚本）

## 编译说明

同 `COMPILE.md`：`sbt "runMain NOP.Main"` → `build/mycpu_top.v`。
骨架独立入口：`sbt "runMain NOP.pipeline.discrete.DiscreteSkeletonGen"`。
