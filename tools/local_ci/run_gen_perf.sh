#!/usr/bin/env bash
# 本地复刻 2026 NSCSCC Team CI 的 gen_perf Job(child.yml)。
# 频率来自团队仓库 src/perf_clock.json(当前 105 MHz)。
# 产物输出到 workspace 根目录:perf_soc_top.bit / .ltx /
# perf_timing_summary.rpt / perf_clock_generated.txt /
# perf_clock_timing_validation.txt

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

verify_chiplab
reset_chiplab_baseline   # 提交状态即 perf 配置,与 CI 全新快照的默认一致
copy_student_rtl

# ---- perf_clock.json 校验(与 child.yml gen_perf 的 python 段逐字一致)----
# 注意:Windows 原生 python 不认识 /d/... 形式的路径,先转成 Windows 形式。
PERF_CLOCK_JSON="$(cygpath -m "$TEAM_REPO_DIR/src/perf_clock.json")"
PERF_CPU_MHZ_TXT="$(cygpath -m "$WORKSPACE_DIR/perf_cpu_mhz.txt")"
python3 - "$PERF_CLOCK_JSON" "$PERF_CPU_MHZ_TXT" <<'PY'
import json
import math
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
try:
    config = json.loads(config_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"ERROR: cannot read {config_path}: {exc}")

if not isinstance(config, dict) or set(config) != {"cpu_clk_mhz"}:
    raise SystemExit(
        "ERROR: perf_clock.json must contain only the cpu_clk_mhz field"
    )

value = config["cpu_clk_mhz"]
if isinstance(value, bool) or not isinstance(value, (int, float)):
    raise SystemExit("ERROR: cpu_clk_mhz must be a JSON number")
value = float(value)
if not math.isfinite(value) or not 10.0 <= value <= 200.0:
    raise SystemExit("ERROR: cpu_clk_mhz must be finite and in 10-200 MHz")

output_path.write_text(f"{value:.6f}\n", encoding="ascii")
print(f"Requested performance CPU clock: {value:.6f} MHz")
PY

PERF_CPU_MHZ="$(tr -d '\n' < "$WORKSPACE_DIR/perf_cpu_mhz.txt")"

cd "$CHIPLAB_DIR/fpga/nscscc-team/run_vivado"

# ---- 重配平台 clk_pll.xci(与 CI 相同的三个参数)----
vivado_batch generate_perf_pll.tcl \
    "$PERF_CPU_MHZ" \
    "$CHIPLAB_DIR/chip/soc_demo/nscscc-team/xilinx_ip/clk_pll/clk_pll.xci" \
    "$WORKSPACE_DIR/perf_clock_generated.txt"

vivado_batch create_project.tcl
# 本地适配:launch_runs 的批量 IP 生成在本机卡 mig_axi_32 的
# updateAllModelParams,bit.tcl 前单独预生成 mig(见 pregen_mig.tcl)。
# vivado_batch 不转换脚本路径,这里先转成 Windows 形式。
vivado_batch "$(cygpath -m "$SCRIPT_DIR/pregen_mig.tcl")"
if ! vivado_batch bit.tcl perf "$PERF_CPU_MHZ"; then
    report_vivado_failure perf \
        project/loongson.runs/impl_1/clock_timing_validation.txt \
        project/loongson.runs/impl_1/timing_summary.rpt
    exit 1
fi

cp project/loongson.runs/impl_1/soc_top.bit ../../../../perf_soc_top.bit
cp project/loongson.runs/impl_1/soc_top.ltx ../../../../perf_soc_top.ltx
cp project/loongson.runs/impl_1/timing_summary.rpt ../../../../perf_timing_summary.rpt || true
cp project/loongson.runs/impl_1/clock_timing_validation.txt ../../../../perf_clock_timing_validation.txt

echo "gen_perf done:"
cat "$WORKSPACE_DIR/perf_clock_timing_validation.txt"
