# nscscc2026 workspace archive (2026-11-23)

Archived from `D:/code/Vivado` before that workspace was deleted.
Purpose: preserve material that existed **only on the local disk** and was not on any remote.
The public mirror `LiaoZiqi-GZFLS/nscscc2026-loongarch-cpu` was already archived (read-only) at that time.

## Branches pushed alongside this archive

| branch | source repo | note |
|---|---|---|
| `t26-freq200` | Loongarch_workspace/T2026143250012561 | 26 commits not on GitHub: 200 MHz rounds P0–P17 (2026-08-13..18), each with func 58/58 results |
| `t26-tlb-3stage-perf` | same | 3 commits: 3-stage fetch + bpu-h7 + dcache-4way, PHT XPM fix |
| `t26-tlb-split` | same | 1 commit: two-stage TLB lookup split experiment |
| `t26-ucore-stable-test` | Loogarch_Linux_workspace/T2026143250012561-ucore-stable | 5 commits (UART file manager, board stability, remote hw server) + backup commit 6c7feec |
| `backup/trio-bdot-w-lru-20260822` | Loogarch_workspace_kimi/t26-perf-submit-trio | 85d6be1: BDOT.W ISA, 2-way D$ LRU, revert of ROB overread/rsp-replica, WINDOWS_BUILD.md |
| `backup/freq200-worktree-20260822` | Loongarch_workspace/T2026143250012561 | a0041ef: uncommitted scala edits + `pipeline/discrete/*` skeleton (never committed) |
| `backup/wt-discrete-perf-20260822` | worktree wt-discrete-perf @ ebc5167 | ae7bb57: regenerated netlist + perf_clock |

## Contents of this branch

- `docs/deepseek/` — 6 analysis reports written during the competition (prefetch study, buffer integration, benchmark analysis, branch comparison…). Never tracked by git.
- `docs/loongarch/` — 200 MHz architecture plan, violation study, Phase1 perf analysis, decision rounds, discrete OoO architecture design (29 KB). The docs directory was gitignored.
- `results/perf/` — gen_perf round r13..r14 netlist-generation logs, sbt elaboration logs, perf/func timing summaries, measured clock.
- `results/analysis/` — Vivado PnR analysis reports (setup violations, logic level distribution, QoR suggestions) per round + `ROBFIFOPlugin_e525573.scala` snapshot.
- `results/bitstreams/` — `perf_soc_top.bit` (2026-08-19) and `func_soc_top.bit` plus LTX probes.
- `results/backup/trepo_uncommitted.diff` — 1.5 MB uncommitted diff snapshot from 2026-08-17.
- `discrete-o3/` — the isolated discrete out-of-order design workspace (`src/`, `docs/设计文档.md`, `WORKLOG.md`). The folder had no git repository.
- `chiplab/` — uncommitted team changes to the gitee chiplab: PLL 100 MHz, UART IRQ wiring, func/perf switch, VIO debug core (IP files), route/impl helper TCLs. Branch tip `fix/ddr-ci-ready-stable-clock-config` @ 68c20a5 is on gitee; the diff and VIO assets here are not.
- `release/` — BDOT.W.pdf (custom instruction spec, never in git), chiplab_custom.zip (chiplab with bdot-w-test feature, 39 MB), T26 Linux demo package, shell patch/probe files.

## Deliberately not archived (reproducible or re-downloadable)

- `NOP-*.zip` and unpacked `nop/` (official Loongson releases, 1.6 GB)
- `simrun_*` simulation outputs (~2 GB), Vivado build dirs, `.Xil`, target dirs
- `Loongarch_ci_workspace` (CI job logs, 47 MB)
- official competition PDFs, 离线测试资料包 (88 MB)
- large netlist snapshots (`analysis_physopt/*.v`, `backup_20260817_100417/*.v`) — regenerable from RTL
- `kimi/chiplab` plain copy (516 MB) — upstream chiplab plus local build outputs
- `kimi/tmp`, `.tmp`, NVIDIA driver logs, Vivado journal/backup logs