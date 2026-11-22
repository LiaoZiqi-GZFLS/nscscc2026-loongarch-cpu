# LoongArch CPU 性能建模与分析

针对龙芯杯团队赛 LA CPU（`T2026143250012561` 仓库 `t26-submit` 分支，
SpinalHDL 乱序核）的 **Python 性能模型**与优化分析。

## 交付物

- `cpu_model/` — Python 模型（译码器、Cache、分支预测器、逐周期乱序时序模拟器、功能模拟器、工作负载、参数扫描）。
- `cpu_model/README.md` — 模型使用说明与微架构参数对照表。
- `性能优化分析报告.md` — 合成负载的扫描结果（已被真实 benchmark 数据取代）。
- `真实benchmark分析.md` — **基于 chiplab 20 个真实 benchmark 的最终结论（推荐）**。
- `预取策略研究.md` — 预取策略（next-line/stride/流缓冲）的量化对比与 RTL 落地建议。

## 运行

```bash
python -m cpu_model.real_bench check      # 20 个真实 benchmark 基线
python -m cpu_model.real_sweep            # 真实 benchmark 优化扫描
python -m cpu_model.analysis              # 合成负载参数扫描（旧）
```

## 核心结论（真实 benchmark 验证）

1. **最大瓶颈是「提交时重定向」**：coremark 实测平均误预测代价 21.1 周期，
   占总周期 ~37%。改为执行时重定向估算 coremark IPC 0.606→0.81（+33%）。
2. **下一行预取**：合计 IPC +11%，访存密集的 fireye_A0 +58%。
3. **gshare 参数（历史位/PHT/BTB/RAS）不是瓶颈**：加大无收益；瓶颈在
   排序类数据依赖分支（bubble_sort 27.9% 误预测）与提交时重定向代价。

