#!/usr/bin/env bash
# discrete-o3 Phase-1 perf build: same as run_gen_perf.sh but student RTL
# comes from the isolated worktree wt-discrete-perf (Phase-1 netlist), leaving
# the team's main checkout untouched.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TEAM_REPO_DIR="$WORKSPACE_DIR/wt-discrete-perf"

verify_chiplab
reset_chiplab_baseline
copy_student_rtl
# round-12: 乘法器 DSP pblock(在 create_project 读 constraints 前放入)
cp "$SCRIPT_DIR/round12_muldiv.xdc" "$CHIPLAB_DIR/fpga/nscscc-team/constraints/round12_muldiv.xdc"
# round-13: 前端/译码/预测器/ROB pblock
cp "$SCRIPT_DIR/round13_pblocks.xdc" "$CHIPLAB_DIR/fpga/nscscc-team/constraints/round13_pblocks.xdc"

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

vivado_batch generate_perf_pll.tcl \
    "$PERF_CPU_MHZ" \
    "$CHIPLAB_DIR/chip/soc_demo/nscscc-team/xilinx_ip/clk_pll/clk_pll.xci" \
    "$WORKSPACE_DIR/perf_clock_generated.txt"

vivado_batch create_project.tcl
vivado_batch "$(cygpath -m "$SCRIPT_DIR/pregen_mig.tcl")"
# round-14: 用 bit_physopt.tcl(route 后 physopt 复制复位网驱动, 消除
# recovery 违例)替代 bit.tcl
cp "$SCRIPT_DIR/bit_physopt.tcl" "$CHIPLAB_DIR/fpga/nscscc-team/run_vivado/bit_physopt.tcl"
if ! vivado_batch bit_physopt.tcl perf "$PERF_CPU_MHZ"; then
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
