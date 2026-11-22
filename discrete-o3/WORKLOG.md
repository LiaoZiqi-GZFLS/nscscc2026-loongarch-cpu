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

### 已验证（2026-08-18）

- ✅ `sbt compile` 通过（87 个源文件，无新错误）。
- ✅ `sbt "runMain NOP.Main"` elaborate 通过 → `build/mycpu_top.v`
  （9.14MB / 154,595 行，较基线净减——fwdCands ~2k LUT 已删）。
- ✅ 网表结构抽查：
  - `fwdCands` 出现次数 = 0（90bit 前递锥彻底删除）；
  - 提交邮箱寄存器就位（`CommitPlugin_mbEntries_0/1_state_*` 148+ 信号、
    `mbValid/mbHasExcept/mbLinearRecover` 16 处）；
  - flush 对齐协议连线正确（`CommitPlugin_needFlush` 驱动 ROB `.flush` 端口 +
    regFlush + fetch/decode flushIt）。
- ✅ **功能仿真 58/58 全 PASS、0 FAIL**（chip 级 xsim，10ms 窗口，测试点 1~58
  全覆盖）——在 `Loogarch_workspace_deepseek/simrun_discrete/` 完成，结果见
  `xsim_func_discrete.log`。环境适配（tb 探测补丁、xpm 40-51 DRC 工作区级修复、
  prj 路径改写）见 `Loogarch_workspace_deepseek/README_discrete.md`。
- ✅ 组合环：elaborate 通过即说明无组合环（SpinalHDL 会在 elaboration 报环）。

### 阶段 1 补全审计（2026-08-18，原计划 3 项全部已由基线覆盖）

| 计划项 | 审计结果 |
|---|---|
| 译码 3 拍化（FB pop 独立成拍） | 基线即 round-10 三拍译码（ID:65 路比较 / ID2:字段 MuxOH / ID3:epilogue，`DecoderArrayPlugin` L181-267）；FetchBuffer pop 已 OutReg 寄存（round-4 修复） |
| 重定向消息链完善 | 邮箱化后 predUpdate/GHR 恢复/BTB 更新均由寄存源驱动（round-4 #1/#4 等效完成）；needFlush→regFlush→各消费者每跳 ≤3 级 |
| axiBuffer FSM 输出寄存 | payload 已 regEntry 寄存（`AxiBuffer.scala` L111-160）；FSM 条件链仅 1~2 级（round-4 #3 已在后续轮次处理） |

### 第一次 perf 构建（200MHz，完成）

- 网表：discrete-o3 Phase-1（elaborate 于 02:36）+ patch_reset_fanout.py。
- 隔离方式：主线 git 仓库新 worktree `wt-discrete-perf`（HEAD=ebc5167 round11b），
  团队工作树零改动；脚本 `local_ci/run_gen_perf_discrete.sh`（TEAM_REPO_DIR 指向
  worktree，其余与 run_gen_perf.sh 一致）。
- 结果：**WNS -3.810 → -2.903（+0.907ns）**；ROB pop 锥 top-100 中 88→2 条 ✓。
- 新头名：FetchBuffer 弹出负载选择链（~90 条，-2.903）+ MULDIV DSP 级联
  （48 条，-2.690）。分析见 `docs/Phase1_perf_分析.md`。

### round-12（收敛：FB 寄存化放弃 + 完整架构实现推进中）

- **FB 弹出负载寄存化**：两次尝试（round-12 与 round-16 基线上的重试）均出现
  均匀 ~4× 变慢+第 21 点停滞，**放弃回退**（保留团队 round-16 功能正确版本）。
  原因未定位（推导逐拍等价），FB 链 13 级修复留待 ID0 独立 pop 拍方案。
- **主线合并（8/18 08:30+）**：discrete-o3/src 已同步团队 round-16 树（含
  round-14 X-sweep、round-16 投机读位宽修复），Phase-1（邮箱 CM1/CM2）已重放。
- **容量扩张**：ROB 32→64（pow2 约束）、INT IQ 7→10（MyCPUConfig）。
- **EXE 提前重定向（round-12 #2 实现）**：BRU 在 WB 拍发现误预测即发起——
  只冲刷年轻项（ROB 尾部压缩 pushPtr/occupancy、IQ/存储缓冲按 robIdx 选择性
  清除、sRAT 立即恢复、取指重定向+前端冲洗）；分支自身保留按序提交（BTB 更新/
  ARF），提交拍以 earlyRedirected 位抑制重复 flush/重定向，空闲表泄漏由提交后
  1 拍的 recoverEarlyReg 脉冲回收（该拍抑制 CM1 fire 保 freeList 不变式）。
- 待验证：58/58 + perf（含 DSP pblock）。

### round-13（IQ 胞元化接入：ready 位面独立成胞元寄存器）

- **改造对象**：`CompressedQueue` / `CompressedFIFO`（三个 IQ 共用）+ 三个
  执行流水的 waken 检查点。
- **位面 `rReadyBank: Vec[Vec[Bool]]`（depth×rPorts）**：每个 (槽,源) ready 位
  只有本胞元一个写者（单写者宪法），唤醒比较在本胞元本地完成，消除 WB→IQ
  的跨区比较长链与 payload valid 的远程覆写。
- **广播寄存一拍**：`genGlobalWakeup` 将 `prf.clearBusys` 用 `RegNext` 寄存成
  `Flow` 广播（模块边界=寄存器宪法，唤醒 +1 拍，功能时序不敏感）。
- **位面生命周期**：入队写初值（`pushPorts(i).payload.rRegs(k).valid`）→ 唤醒
  `when(waken) rReadyBank(i)(j) := True` → 压缩随指令搬移（`rReadyBank(i) :=
  rReadyBank(i+j)`）→ flush/earlyKill 清零。
- **消费端改读位面**：三个执行流水 ISS 的 waken 检查由 `slot.rRegs(j).valid`
  改为 `IQ.rReadyBank(i)(j)`；槽 payload 的 `rRegs.valid` 保留为入队写（供
  issue 负载携带，下游只用 tag），**删除 genReadyCopy**（此前造成
  ASSIGNMENT OVERLAP 双驱动）。
- **两处关键修复**：
  1. genGlobalWakeup 初版在 IQ 插件 build 期（DISPATCH plug 内）调用，此时
     执行插件尚未 build、`prf.clearBusys` 为空/不全 → 部分 WB 无广播 →
     依赖者永等 → **整机启动死锁（58/58 得 0 点、wb_pc 恒 0）**。改为在
     `afterElaboration` 调用（clearBusy 端口已全部注册，网表实测 4 路广播
     比较齐全）。
  2. 位面寄存器创建拆为 `createReadyBank`（build 期调用，先于执行插件 ISS
     读位面，否则 NPE）。
  3. **唤醒与压缩同拍丢唤醒（第二次死锁，真正的根因）**：RegNext 广播只存活
     1 拍，若唤醒拍恰好与压缩搬移同拍，位面行搬走的是旧值（寄存读），广播已
     消失 → 唤醒永久丢失 → IQ 填满死锁。修复：位面加 `rReadyBankNext =
     CombInit(rReadyBank)`，与团队 payload/queueNext 模式严格镜像——唤醒/入队
     双写寄存+next，压缩搬 next（`rReadyBank(i) := rReadyBankNext(i+j)`）。
- 状态：修复后 elaborate 通过；58/58 待跑。

### round-13 追加（2026-08-18 上午，xsim 信号探针定位两个独立 bug）

- **探针方法**：复用已生成的 `tb_top_snapshot`，用 xsim `tclbatch` + `get_value`
  （路径用 `/` 分隔符）+ `add_condition` 定点捕获；关键信号名见网表
  （`toplevel_cpu/...`，INT 位面命名随消费者为 `_zz_IntExecutePlugin_issReqs_*`）。
- **bug#1（位面唤醒丢拍）**：RegNext 广播只存活 1 拍，唤醒拍与压缩搬移同拍时
  位面行搬走旧值 → 唤醒永久丢失 → IQ 填满死锁。修复：`rReadyBankNext =
  CombInit(rReadyBank)` 镜像 queueNext（见上 round-13 修复 3）。
- **bug#2（EXE 提前重定向与提交 pop 竞态，真正的本轮死锁）**：探针实测两次
  重定向（4.19µs robIdx=2、14.46µs robIdx=23 恰为提交头）。squash 把
  `pushPtr:=robIdx+1`、`occupancy:=robIdx-popPtr+1`，但提交侧 CM1 的 pop
  决策独立进行：squash 生效拍前后 commit 仍 pop 掉被冲刷区条目（24/25/26），
  popPtr 钻进冲刷区停在 27——该头项已被冲刷、永不完结 → 提交永久阻塞 →
  freeList 枯竭（RENAME noFreeRegs 停摆）→ 整机冻结。基线 19~20 点停滞
  极可能就是同一竞态（时序不同、发作较晚）。
  **修复**：CM1 三个 pop ready 加 `!robFIFO.earlyRedirect.valid` 门控
  （squash 生效拍抑制提交 pop，1 拍后按新 occupancy 续提；与既有
  recoverEarlyReg 抑制同模式）。
- **bug#3（早重定向后旧流残留泄漏，死锁真正主因）**：逐拍追踪（10ns 步长）
  显示 squash 后 3 拍内，旧流顺序取指的残留指令（PC 0x1c000054..60）仍被
  派发进被 squash 的 ROB 区（24~27 号槽）——其操作数生产者已被冲刷、永不
  完结，提交卡死在 27 号死项（complete=0）。三条泄漏路径逐一封堵：
  1. FetchBuffer 只在 needFlush 清空 → 加 `|| earlyRedirect.valid`；
  2. ROB push 口用 `isValidNotStuck`（不含 removeIt），flush 拍仍推入 →
     `port.valid` 加 `!earlyRedirect.valid`；
  3. 三个 IQ 的 DISPATCH 入队口同门控（防残留进 IQ 后 WB 写坏新流 ROB 项）。
  注：常规 flush 无此问题（ROB pushPtr 清零，泄漏项被后续 push 覆盖）。
- **bug#4（EXE 提前重定向的空闲表恢复根本性破坏，功能点错误的真因）**：
  二分实验（团队 payload 直写唤醒 vs 位面版）证明 0/1/2 点错误与 IQ 胞元化
  无关（错误时刻逐 ns 一致）。根因：`freeList.recover` 的 `pushPtr := popPtr`
  把**所有**未提交分配回满——包括重定向后仍存活的新流指令的映射 → 被新
  rename 复用 → WAW 覆写 → 基本测试错。正确修法需在 squash 拍快照被冲刷项
  prevAddr 逐拍回推（ROB 槽很快被覆写，提交后 1 拍的 recoverEarlyReg 拿不到
  数据）。**当务收敛：暂禁 earlyRedirect 发射**（`earlyRedirectDisabled=True`），
  回落提交侧重定向（已知 58/58 正确）；squash/门控机制保留空转。
  待 58/58 + perf 后再按快照方案重做。
- **58/58 回归（早重定向禁用后）**：13 点全 PASS、0 错（点 1~13 均匀
  ~480µs/点）——功能正确性恢复。速度二分：容量回退（ROB 64→32、IQ 10→7）
  与广播组合化（去 RegNext）均无速度变化（pass 时刻逐 ns 一致）→ 慢不是
  位面/容量引起，在团队 round-16 大堆（ICache/DCache/PC/AxiBuffer 等 ~30
  文件，r11b→r16 diff 见上）。早重定向禁用本身损失 ~1.5×（09:21 带早重
  定向 20 点）。58/58 全速回归需：早重定向按快照方案重做 + 定位 r16 慢因
  ——留作后续轮次。
- **perf 构建已启动**（RegNext 宪法版 + patch_reset_fanout.py，网表已放
  wt-discrete-perf/src/mycpu/mycpu_top.v，DSP pblock 脚本内置；对照基线
  WNS -2.903）。

### round-13 追加 2（2026-08-18 下午）：perf 结果 + 早重定向快照重做

- **perf 结果（200MHz）**：WNS **-4.158ns** / TNS -40.2ns / 28,751 失败端点
  （CPU 侧 ~37% 端点违例）。头号路径 = 取指侧
  `IF1_regPC → ICache dataRAM → IF2_ICACHE_RSPS`（逻辑仅 2 级 0.71ns、
  **布线 8.43ns 占 92%**、fo=604 高扇出网 + 跨远端布局）——团队 r16 的
  ICache/PC 改动引入，与 IQ 胞元化/提交链无关（其结构不在 top 违例）。
  复位组(async_default cpu_clk)WNS -1.943/458 端点——patch_reset_fanout 在
  新网表风格（合并 always、仅 19 处文本引用）下效果弱化。
  对照：Phase-1 基线 -2.903（r11b 基）→ 团队 r16 状态 -3.301（08:40 自跑）→
  本轮 -4.158。r16 合并约 +0.4ns，其余为取指侧布线退化+方差。
- **早重定向快照式重做（实现 + elaborate 通过）**：
  - CommitPlugin 影子表 `recoverShadow[robDepth]`（派发侧记录 doRegWrite##
    wPrevReg，与 ROB push 同门控）→ squash 拍并行快照被冲刷弧
    (robIdx+1..pushPtr-1) 入 `snapData` → 逐拍 1 项经 `arfCommits` 扩展末槽
    （retireWidth+1）并入 RenamePlugin 压缩网络回推 freeList（addr=0 占位、
    aRAT 更新门控 addr=/=0）；freeList 扩 push 口 retireWidth→retireWidth+1。
  - 删除旧 recoverEarlyReg（freeList.recover 全量回滚破坏新流映射）。
  - 早重定向发射重新启用（IntExecutePlugin）。
  - 58/58 验证中。

### round-13 追加 3（2026-08-18 晚）：早重定向快照重做的调试与收敛

- **快照重做实现完成**（影子表 + squash 拍并行快照 + arfCommits 扩展末槽
  回推 + freeList 扩口 + drainActive 抑制 CM1 + 上升沿脉冲化非幂等消费者 +
  捕获式锁存单脉冲 + 跳转 4 拍 hold），elaborate 全通过。
- **调试实录（xsim 逐拍探针）**：
  1. 回推与提交 push 并发超 freeList 空闲空间→末位回推项丢弃→寄存器泄漏
     → drainActive 抑制 CM1；
  2. 6 拍 hold 内后续 WB 持续覆写 robIdx 负载（实测 23→27 漂移，快照弧长
     算成 31→回推垃圾项→寄存器错释放）→ 捕获式锁存 + 单脉冲；
  3. 单脉冲跳转被 ICache refetch 握手错过→前端排空冻结 → 跳转 4 拍 hold。
- **现状（收敛）**：重启用后仍冻结（0 点 0 错，ROB 空转、前端排空、各级
  valid=1 但不 fire——跳转/前端重填交互仍未完全收敛，疑似还有 1~2 个
  消费者时序问题）。**决策：暂回禁用态**（`earlyRedirectDisabled := True`，
  回落提交侧重定向，58/58 13 点 0 错），快照机制全量保留在树中、gated off。
  下一轮：以"重启后逐拍对照禁用态行为"为主线，先复现 4.25µs 第一次重定向
  后的前端排空，再定位最后 1~2 个时序问题；解完改 False 即可启用。
- **冻结点精确定位（round-13 追加 3 的最后一轮探针，供下一轮直接接续）**：
  重定向拍（~4.2µs）起，ICache refill FSM 卡死在 **readMem 态**（haltItself
  =1，IF1/2/3 全 stuck）：AR 已握手（arr=1）但 **R 通道只回了一个 beat
  （~6.0µs rv=1）后永久静默**——AXI 突发中途停顿。疑点：重定向的 fetch
  flushIt（earlyRedirRising 脉冲）与 refill FSM 的 refetch 协议交互（
  finish 态 `when(!isStuck) goto(stateBoot)` 依赖自身 halt 解除的自环），
  或 AR 地址取自被 flush 的 physPC 而指向无效行。下一轮直接探 3.5~4.5µs
  的 AR 地址/首个 R beat，对比禁用态同一时刻的 AXI 行为。
- **最终定论（round-7 对照探针）**：启用版**不是死锁**——对照探针证明两版
  在 4.2~10µs 行为同构：tb RAM 慢模型（R 拍 ~2µs 间隔）导致每次 boot 迭代
  都触发同一行的 refill（refetch 持续 miss 刚填入的行，两版共有），机器以
  refill 为限速爬行；启用版 ROB 正常推进（3→7@8.4µs），只是叠加重定向后
  整体慢到 9.9ms 内 0 点（对照 13 点）。早重定向结构本身工作正常，但在该
  仿真环境下收益为负。**维持禁用**；后续若在真实频率（无慢 RAM 模型）下
  复测，改 `earlyRedirectDisabled=False` 即可。

### round-14（读进胞元双总线，INT 流水先行）

- 实现（设计文档 §4.5 B / §4.6 #1 的标准形态，elaborate 通过）：
  1. `IntIssueSlot` 加 `rData: Vec[UInt(32),2]`——操作数数据进胞元；
  2. 派发侧 6 口 PRF 读（decodeWidth×rPorts）存初值（IntIssueQueuePlugin
     DISPATCH，`slot.rData(j) := PRF.readPort(busyAddrs)`）——生产者在派发前
     已写回则初值即真值，否则旧值待唤醒修正；
  3. 数据总线捕获（IntIssueQueuePlugin afterElaboration）：广播 tag 的 PRF
     同拍读 + `!rReadyBank(i)(j)` 门控——只有"本拍才被唤醒"的槽才捕，
     标签复用的假匹配不覆写已就绪槽；捕获与位面置位同拍（边沿），发射拍
     两者同时可见，依赖链 4 拍不变；
  4. INT EXE 操作数改读 `issSlot.rData`（REG_READ_RSP 留为死逻辑，RRD 读树
     移出发射关键环集中到派发侧）。
- MULDIV/MEM 流水保留 RRD（后续轮次跟进）。
- **调试实录**：初版 1 点 2 错（27.2µs/1.6ms）——捕获只写 payload 寄存器、
  压缩搬移取 queueNext 组合值 → "捕获拍与压缩同拍"丢数据（与位面 next 面
  同款竞态）；修复（捕获双写 payload+queueNext）后 0 点 1 错（43.7µs，
  错误数降为 1，时刻后移）——**仍有 1 个竞态未定位**。已知安全性论证：
  捕获门控 `!rReadyBank` 挡住标签复用假匹配；同组 RAW 由 freeList pop 时
  置 busy 覆盖（派发读 busy=1 → 唤醒捕获）。下一轮：对照 13 点基线逐拍
  diff 提交流定位首错指令，或按剩余竞态清单（初始化/捕获/搬移三方时序、
  双操作数同拍唤醒）逐项核查。
- **竞态 #2 定位并修复（round-9，关键）**：LSU 的 clearBusy 在 MEM1 发
  （团队"推测唤醒，一个气泡"——比数据写回早 2 拍）。旧设计 RRD 在发射拍
  读 PRF 吸收该窗口；读进胞元在唤醒拍读 PRF → load-use 消费者拿到旧值。
  **修法：clearBusy 移到 MEM 流水 WB 拍**（与数据写回同拍，唤醒拍读即
  真值；load-use +2 拍，正确性优先；SpeculativeWakeupHandler 的
  regWakeupFailed 保留，退化为性能抖动、无死锁——已论证）。
  效果：**10 点 PASS（2~10、12）、3 错**（43.7µs 的旧错未消——另一竞态，
  与 11/13 点后段错）。剩余竞态清单：43.7µs 首错（ALU/初值读路径）+
  11/13 点稀有错。
- **探针实证（round-10）**：三条 INT 流水 10~48µs 逐拍比对 rData 与 PRF
  实值（按 use 位/标签动态索引）——**零偏差**：初值读 + 数据总线捕获的
  操作数数据路径是干净的。结论：剩余 3 错不在 INT 操作数数据——嫌疑转向
  MULDIV/MEM 流水（11/13 点含乘除法/访存测试）与 43.7µs 首错的其他输入
  （CSR/Timer 路径或 1 拍级闪错，100ns 网格可能漏采）。下一轮：10ns 网格
  重扫 + MULDIV/MEM 的 RRD 数据对拍。
- **round-11 深挖**：失败点 = n1_lu12i/n11_slli/n13_srai（纯 ALU 立即数/
  移位测试，紧 RAW 依赖链循环）；43.38µs 提交流确认机器进入 `inst_error`
  （测试自检失败）。**10ns 网格重扫 INT0/INT1/INT2（33~44µs，n1 全程）
  零偏差**——操作数数据路径结论性干净（初值/捕获/搬移/发射链均正确）。
  剩余嫌疑：EXE 计算路径（src1/src2 的 alternative mux、aluOp/useRk 的
  MuxOH 载荷）或控制路径（提交流中 44~45µs 的 flush 回 0x1c000154 需查——
  是误预测还是异常？）。下一轮：提交流分叉点对照（控制 vs 双总线版）+
  EXE 输入全字段对拍（不只 rData）。
- **round-15 根因定位（生成顺序宪法）**：与团队基线逐行 diff 确认 EXE 改动仅
  三项（waken 源、regData 源、禁用中的早重定向）。静态分析发现捕获块的
  elaboration 生成顺序错误——捕获生成在 enqueue/compress **之后**（最后写入者
  优先），当"旧槽 i 未就绪且本拍收到其 tag 广播"与"就绪槽搬入位置 i"同拍
  碰撞时，捕获的部分 rData 写**覆盖**压缩搬移的整槽写：搬入槽 uop 是新槽、
  rData 是旧槽的捕获值——错值进 PRF 后对拍探针恒等无法发现（探针盲区）。
  团队 wakeup 生成在**最前**、整槽写在后覆盖、唤醒值经 queueNext 镜像跟随
  内容——语义正确。**修复：捕获块移至 afterElaboration 最前**（先于
  wakeup/enqueue/compress），与团队宪法严格对齐；MULDIV/MEM 队列无捕获、
  顺序本就正确，无需改动。等待 58 门复测。

### 主线对齐状态（2026-08-18 08:15，重要）

- 主线团队已推进到 round-16/17（工作树未提交）：`CommitPlugin.scala`（07:27）、
  `ROBFIFOPlugin.scala`（03:20）、`MultiPortFIFOVec`（05:34）、`FetchBufferPlugin`
  （07:27）、`RenamePlugin`、`Pipeline.scala`、`CompressedQueue`、`ICache/DCache`
  等 16 个文件均有新改动。
- **团队未合入 Phase-1**（其 CommitPlugin 无 mbValid/mbEntries；ROBFIFO 仍有
  fwdCands）——两条线并行演进。
- **下一步建议**：等团队暂停后，把 Phase-1 的 CommitPlugin/ROBFIFOPlugin 两文件
  差异 rebase 到团队 round-16 树（discrete-o3 的两个文件即参考实现），再走
  58/58 + perf。合并时注意团队 07:27 的 CommitPlugin 改动方向（未知，需先 diff）。

### 未包含在本阶段（文档 §8 阶段 2/3/4）

- SystolicIssueQueue 替换 CompressedQueue（骨架在 `src/pipeline/discrete/`）
- 译码 3 拍化、EXE 提前重定向、读进胞元双总线、写引擎广播合并、容量扩张
- axiBuffer FSM、pblock、复位网拆分（芯片级流程，需主线脚本）

## 编译说明

同 `COMPILE.md`：`sbt "runMain NOP.Main"` → `build/mycpu_top.v`。
骨架独立入口：`sbt "runMain NOP.pipeline.discrete.DiscreteSkeletonGen"`。
