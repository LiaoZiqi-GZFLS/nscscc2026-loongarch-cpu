#!/usr/bin/env bash
# perf 仿真补丁——真实内存延迟版:保留平台原始 R 通道延迟
# (R_Delay_Multiple=85,不定义 RUN_PERF_NO_DELAY),只做缓存窗口重映射
# 与 AW 扩容。用于预取收益在真实延迟下的对比(零延迟下预取无意义)。
set -euo pipefail

CHIPLAB="/d/code/Vivado/Loongarch_workspace/chiplab"
RTL="$CHIPLAB/chip/soc_demo/nscscc-team"

git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/soc_config.vh
git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/ram_wrap/axi_wrap_ram.v
git -C "$CHIPLAB" checkout -- chip/soc_demo/nscscc-team/ram_wrap/fpga_sram_dp.v

# 1) 缓存窗口重映射(ar/aw,perf 模式)——与 func 一致
python3 - "$RTL/ram_wrap/axi_wrap_ram.v" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
for chan in ("ar", "aw"):
    old = f"`ifdef RUN_PERF_TEST\nassign ram_{chan}addr  = axi_{chan}addr ;\n`else"
    new = (f"`ifdef RUN_PERF_TEST\n"
           f"// SIM-PATCH: 与 func 模式一致的重映射(缓存窗口 0x8/9xxx -> 物理)\n"
           f"assign ram_{chan}addr  = (axi_{chan}addr[31:28] == 4'h0 ||\n"
           f"                      axi_{chan}addr[31:28] == 4'h1 ||\n"
           f"                      axi_{chan}addr[31:28] == 4'h7) ? axi_{chan}addr :\n"
           f"                      {{12'b0, 4'hf, axi_{chan}addr[31:28], axi_{chan}addr[11:0]}};\n"
           f"`else")
    assert s.count(old) == 1, f"{chan} block: {s.count(old)}"
    s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
print("axi_wrap_ram remap patched")
PY

# 2) AW 16 -> 20
sed -i 's/parameter AW = 16/parameter AW = 20/' "$RTL/ram_wrap/fpga_sram_dp.v"
grep -n "parameter AW" "$RTL/ram_wrap/fpga_sram_dp.v"
grep -n "RUN_PERF_NO_DELAY" "$RTL/soc_config.vh" || echo "(NO_DELAY undefined — 原始延迟生效)"
echo "DELAY PATCHES DONE"
