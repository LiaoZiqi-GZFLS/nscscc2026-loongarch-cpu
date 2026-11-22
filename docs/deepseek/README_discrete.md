# discrete-o3 阶段 1 验证环境（DeepSeek 工作区）

> 2026-08-18 搭建。基线：主工作区 `Loongarch_workspace\T2026143250012561`（8/17，
> round-9，58/58 通过、perf WNS -3.810ns）。本区 T2026143250012561 仓库是
> t26-bpu-h7 基线（更旧），**未改动**；阶段 1 的所有工作在独立目录进行。

## 目录说明

| 路径 | 内容 |
|---|---|
| `discrete-o3/` | 阶段 1 源码副本（ROBFIFOPlugin 删 fwdCands、CommitPlugin CM1/邮箱/CM2），`WORKLOG.md` 为改动与验证记录 |
| `discrete-o3/build/mycpu_top.v` | Phase-1 elaborate 网表（9.14MB） |
| `simrun_discrete/` | chip 级 xsim 工作目录（从主工作区 simrun_p0 复制 + 路径改写 + 补丁网表） |
| `simrun_discrete/mycpu_top_p1.v` | Phase-1 网表 + patch_reset_fanout.py 复位扇出补丁 |
| `simrun_discrete/run_func_discrete.bat` | 58/58 功能仿真一键流程（xvlog→xvhdl→xelab→xsim 10ms） |
| `simrun_discrete/xsim_func_discrete.log` | 仿真总日志（结果判读处） |
| `local_ci/` | 从主工作区复制的 sim_ip 网表 + mycpu_tb_p1.sv + patch_reset_fanout.py |
| `chiplab/IP/myCPU/` | 本区新补：core_top.v（复制自 T2026143250012561/src/mycpu）+ multiplier synth VHDL（复制自主工作区 chiplab） |

## 复现流程

1. RTL 修改（`discrete-o3/src/`）后重新 elaborate：
   ```
   cd discrete-o3
   sbt "runMain NOP.Main"            # -> build/mycpu_top.v
   ```
2. 打补丁并生成仿真网表：
   ```
   python3 local_ci/patch_reset_fanout.py discrete-o3/build/mycpu_top.v simrun_discrete/mycpu_top_p1.v
   ```
3. 切换功能测试（脚本已处理 soc_config.vh 的 RUN_FUNC_TEST 切换；跑完记得恢复）：
   ```
   cmd /c simrun_discrete\run_func_discrete.bat
   ```
4. 判读：`simrun_discrete/xsim_func_discrete.log` 尾部（PASS/FAIL 计数）。

## 环境适配说明（从主工作区移植到本区时踩的坑）

1. **prj 路径改写**：prj_new.vlog / tb_top_vhdl_new.prj 中所有绝对路径已从
   `Loongarch_workspace` 改写为本区 `Loogarch_workspace_deepseek`。
2. **testbench 版本**：本区 chiplab 的官方 mycpu_tb.sv 与 soc_top 端口不配套
   （版本偏差），必须用主工作区 `local_ci/mycpu_tb_p9.sv`（已复制到本区
   `local_ci/` 并按 Phase-1 网表改过）：
   - retireWidth=2 → pop_2 探测清零为常量；
   - FSM 探测路径改为 `CommitPlugin_uncachedProcess_fsm_stateReg`；
   - 被优化器裁掉的内部调试网（IF3_ICachePlugin_fetchPacket_pc 等）探测清零；
   - P9DBG 窗口从 1.4ms 扩到 9.9ms（原 tb 硬编码 $finish 会截断 58 点测试）。
3. **XPM_MEMORY 40-51 仿真 DRC**：当前基线网表的 PHT xpm 存储（4×16384bit）
   触发 Vivado 预编译 xpm 库的 40-51 检查（源码里该检查本不该触发，预编译库
   行为不一致），$finish 中止仿真。修复：`C:\Xilinx\Vivado\2023.2\data\ip\
   xpm\xpm_memory\hdl\xpm_memory.sv` 的 40-51 条件改为 `1'b0`（原文件备份
   `.discrete_bak`），并把 xpm_memory.sv / xpm_fifo.sv 加入 prj 的 sv 段
   （编入 xil_defaultlib，优先于预编译 xpm 库）。注意：这是仿真专用 DRC，
   与综合/实现无关。

## 与主线的接口约定

- 验证通过后，把 `discrete-o3/build/mycpu_top.v`（或补丁版）交给主线：
  `src/mycpu/mycpu_top.v` 替换 + regen + 58/58 + perf 构建（主线 CI 环）。
- 本区 `T2026143250012561`（t26-bpu-h7 + 未提交预取改动）与 `wt/` worktrees
  **均为既有实验状态，勿动**；阶段 1 的 git 化提交待主线决策基线后再做。
