# local_ci — 本地复刻 2026 NSCSCC Team CI 的 gen_func / gen_perf

在 Windows + Git Bash + Vivado 2023.2 上 1:1 复刻
`nscscc-team-ci/child.yml` 的 `gen_func` / `gen_perf` Job(bitstream 生成
及时序门禁,不含 program_* 实板环节)。

## 目录约定

| 路径 | 内容 |
| --- | --- |
| `../chiplab` | gitee chiplab,`fix/ddr-ci-ready-stable-clock-config` 分支,HEAD 固定 `68c20a5` |
| `../T2026143250012561` | 团队仓库 clone(CI 中的 `$CI_PROJECT_DIR`),提供 `src/mycpu` 与 `src/perf_clock.json` |
| `../func_*` / `../perf_*` | 构建产物,输出到 workspace 根目录(与 CI 一致) |

## 用法

```bash
# 功能测试 bitstream + 时序门禁
./run_gen_func.sh

# 性能测试 bitstream + 时序门禁(频率取 src/perf_clock.json 的 cpu_clk_mhz)
./run_gen_perf.sh
```

每个脚本运行前会:

1. 校验 chiplab HEAD == `68c20a539e2be8a05300e714296f5fda8373ee80`;
2. `git checkout --` 复位 `soc_config.vh`(本地复用目录,等价于 CI 的全新快照);
3. 清空 `chiplab/IP/myCPU` 并复制 `src/mycpu`。

## 与 CI 的差异

- CI 从只读快照 `git archive` 导出 chiplab;本地直接使用 clone 出的工作目录,
  靠 git 复位唯一会被修改的跟踪文件 `soc_config.vh`。
- Vivado 经 `vivado.bat` 批处理模式调用(`MSYS_NO_PATHCONV=1`,绝对路径参数
  自动转 Windows 形式);三个 tcl 脚本本身无需改动。
- 不执行 program_func/program_perf(需要 FPGA 板卡,只能在服务器跑)。

## 产物

| func | perf |
| --- | --- |
| `func_soc_top.bit` / `.ltx` | `perf_soc_top.bit` / `.ltx` |
| `func_timing_summary.rpt` | `perf_timing_summary.rpt` |
| `func_clock_timing_validation.txt` | `perf_clock_timing_validation.txt` |
| | `perf_clock_generated.txt` |

时序门禁:sys_clk = 100 MHz、DDR = 200 MHz、perf 实际 CPU 频率误差 ≤ 1%、
setup/hold WNS ≥ 0,任一不满足则判失败并保留诊断产物。
