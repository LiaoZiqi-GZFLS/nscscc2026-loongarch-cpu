#!/usr/bin/env bash
# perf 功能仿真(xsim)的 chiplab 补丁集——perf 测试程序链接到缓存窗口
# (0x8/0x9xxx),仿真 RAM 需要与 func 模式一致的重映射;R 通道模拟延迟
# 170 周期,对比实验统一用 RUN_PERF_NO_DELAY 关掉以加快仿真(两轮设置
# 一致,相对比较有效);fpga_sram_dp AW 扩到 20(1MB)容纳 allbench 程序。
# 注意:这些补丁只用于 xsim 功能/性能仿真,gen_func/gen_perf 前会被
# reset_chiplab_baseline 清掉,与 CI 流程无交集。
set -euo pipefail

CHIPLAB="/d/code/Vivado/Loongarch_workspace/chiplab"
RTL="$CHIPLAB/chip/soc_demo/nscscc-team"

# 1) soc_config: RUN_PERF_TEST + RUN_PERF_NO_DELAY
git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/soc_config.vh
sed -i 's|^// `define RUN_PERF_NO_DELAY$|`define RUN_PERF_NO_DELAY|' \
    "$RTL/soc_config.vh"
grep -n "RUN_PERF_TEST\|RUN_PERF_NO_DELAY" "$RTL/soc_config.vh" | head -4

# 2) axi_wrap_ram: perf 模式缓存窗口重映射(ar/aw) + NO_DELAY 下
#    r_countcmp 恒 0
git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/ram_wrap/axi_wrap_ram.v
python3 - "$RTL/ram_wrap/axi_wrap_ram.v" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

# ar 重映射
old_ar = "`ifdef RUN_PERF_TEST\nassign ram_araddr  = axi_araddr ;\n`else"
new_ar = ("`ifdef RUN_PERF_TEST\n"
          "// SIM-PATCH: 与 func 模式一致的重映射(缓存窗口 0x8/9xxx -> 物理)\n"
          "assign ram_araddr  = (axi_araddr[31:28] == 4'h0 ||\n"
          "                      axi_araddr[31:28] == 4'h1 ||\n"
          "                      axi_araddr[31:28] == 4'h7) ? axi_araddr :\n"
          "                      {12'b0, 4'hf, axi_araddr[31:28], axi_araddr[11:0]};\n"
          "`else")
assert s.count(old_ar) == 1, f"ar block: {s.count(old_ar)}"
s = s.replace(old_ar, new_ar)

# aw 重映射
old_aw = "`ifdef RUN_PERF_TEST\nassign ram_awaddr  = axi_awaddr ;\n`else"
new_aw = ("`ifdef RUN_PERF_TEST\n"
          "// SIM-PATCH: 与 func 模式一致的重映射(缓存窗口 0x8/9xxx -> 物理)\n"
          "assign ram_awaddr  = (axi_awaddr[31:28] == 4'h0 ||\n"
          "                      axi_awaddr[31:28] == 4'h1 ||\n"
          "                      axi_awaddr[31:28] == 4'h7) ? axi_awaddr :\n"
          "                      {12'b0, 4'hf, axi_awaddr[31:28], axi_awaddr[11:0]};\n"
          "`else")
assert s.count(old_aw) == 1, f"aw block: {s.count(old_aw)}"
s = s.replace(old_aw, new_aw)

# r_countcmp: NO_DELAY 下恒 0(4 个 lane)
for i in range(4):
    old = f"r_countcmp <= (r_count[{i}]+1'b1) * R_Delay_Multiple;"
    new = (f"`ifdef RUN_PERF_NO_DELAY\n"
           f"                    r_countcmp <= 32'h0;\n"
           f"                `else\n"
           f"                    {old}\n"
           f"                `endif")
    assert old in s, f"lane {i} not found"
    s = s.replace(old, new)

open(p, "w", encoding="utf-8").write(s)
print("axi_wrap_ram patched")
PY

# 3) fpga_sram_dp: AW 16 -> 20(1MB 寻址)
git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/ram_wrap/fpga_sram_dp.v
sed -i 's/parameter AW = 16/parameter AW = 20/' \
    "$RTL/ram_wrap/fpga_sram_dp.v"
grep -n "parameter AW" "$RTL/ram_wrap/fpga_sram_dp.v"

echo "PATCHES DONE"
