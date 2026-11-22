# t26-perf-cache 分支对比分析

> 对比 t26-submit（旧）与 t26-perf-cache（新）在真实 chiplab benchmark 上的性能，
> 用 `cpu_model` 量化，并指出该分支改动的效果与下一步方向。

## 1. 分支改了什么

| 类别 | 改动 | 性质 |
|------|------|------|
| DCache | 2-way LRU → **4-way round-robin** | 性能（解决冲突缺失）|
| BPU | PHT 8192→**32768**，history 5→**7**，冷启动 1→**0** | 性能（放大 gshare）|
| 取指 | 加 **IF3** 级（IF1 发 RAM 读+TLB stage1，IF2 解析 physPC，IF3 命中/refill/组包）| 时序 |
| TLB | 翻译拆成 stage1/stage2 两级 | 时序 |
| 除法 | early-out 判断加一级寄存器 `in16BitsHeld` | 时序 |
| FIFO/RAM | MultiPortFIFO 读地址不依赖 popCount、ReorderCacheRAM 响应副本 | 时序 |

**结论：性能改动只有 2 处（4-way DCache、gshare 放大），其余全是时序优化
（为 105MHz+ 铺路）。**

## 2. 模型对比（真实 benchmark，40 万条指令/项）

| benchmark | 旧 IPC | 新 IPC | 变化 |
|-----------|-------|-------|------|
| coremark | 0.591 | 0.587 | −0.6% |
| dhrystone | 0.697 | 0.697 | −0.1% |
| bubble_sort | 0.337 | 0.339 | +0.4% |
| quick_sort | 0.586 | 0.593 | +1.1% |
| crc32 | 0.846 | 0.845 | −0.2% |
| stream_copy | 0.776 | 0.779 | +0.5% |
| fireye_A0 | 0.352 | 0.355 | +0.8% |
| fireye_D1 | 0.509 | 0.521 | +2.5% |
| stringsearch | 0.484 | 0.485 | +0.1% |
| sha | 0.559 | 0.555 | −0.7% |
| **合计** | **0.529** | **0.531** | **+0.3%** |

**DCache MPKI（每千条需求缺失）**

| benchmark | 旧 | 新 | 说明 |
|-----------|-----|-----|------|
| dhrystone | 1.40 | 0.98 | 冲突缺失被 4-way 解决 |
| quick_sort | 1.94 | 1.29 | 同上 |
| stream_copy | 1.09 | 0.80 | 同上 |
| stringsearch | 1.25 | **0.58** | 冲突缺失大幅下降 |
| fireye_A0 | 30.61 | 29.93 | **几乎不变（流式缺失，4-way 无效）** |
| fireye_D1 | 16.51 | 15.09 | 几乎不变（流式） |

**误预测率**

| benchmark | 旧 | 新 |
|-----------|-----|-----|
| coremark | 14.38% | 14.99%（略升）|
| dhrystone | 5.46% | 6.03%（略升）|
| bubble_sort | 28.35% | 27.05%（略降）|

## 3. 结论：这个分支几乎没有性能进步（+0.3%）

原因很清楚：

1. **DCache 4-way 只解决"冲突缺失"**，但真实 benchmark 里：
   - 大多数项 DCache MPKI 本来就不高（<2），4-way 的收益被乱序/按序 LSU 掩盖；
   - fireye_A0/D1 的高 MPKI 是**流式（sequential）缺失**——4-way 解决不了，
     **只有预取能解决**（之前测过 next-line 预取使 fireye_A0 +53%、fireye_D1 +39%）。

2. **gshare history 5→7 不是瓶颈，甚至略有害**：coremark 误预测率 14.38%→14.99%、
   dhrystone 5.46%→6.03%。因为 PHT 索引 = `GHR @@ PC[9:2]`，history 从 5 加到 7
   挤掉了 2 个 PC 位，**别名更重**。这完全印证了之前"单纯加历史位不加大 PHT 比例
   会别名变差"的结论（现在 PHT 32K 其实够大，但 PC 位仍是 8 位，history 7 时
   GHR 7 位 + PC 8 位 = 15 位恰好填满 32K，问题不大，但 history 对这套负载无用）。

3. **真正的瓶颈一个都没动**：
   - **提交时重定向**（误预测代价 21.1 周期，占 coremark 总周期 ~37%）——没改；
   - **预取**（合计 +15%、fireye_A0 +58%）——没加。

## 4. 建议：下一步优先级

| 优先级 | 优化 | 预期收益 | 状态 |
|--------|------|---------|------|
| **P0** | 执行时重定向（替代提交时重定向）| coremark 估算 +33%，branch 型全面受益 | 未做 |
| **P1** | next-line 预取（流缓冲，度1）| 合计 +15%，fireye_A0 +53% | 未做（有改动清单 `流缓冲接入改动清单.md`）|
| P2 | 4-way DCache | +0.5%（已做）| ✅ 本分支 |
| P2 | PHT 32K/history 7 | ≈0（已做）| ✅ 本分支 |

**一句话**：这个分支的 4-way + gshare 放大方向没错、但都是 P2 级小改，且**时序优化
（IF3/TLB 两级/除法寄存器化）才是本分支真正的价值**——为提频铺路。要拿性能分，得
做 P0（执行时重定向）和 P1（预取）。

> 注：模型里 PHT 冷启动 init（旧=1、新=0）已参数化（`BPUConfig.pht_init`），
> 对 40 万条指令的 trace 影响 <0.5%，不改变结论。
