#!/usr/bin/env bash
# 本地复刻 2026 NSCSCC Team CI 的 gen_func Job(child.yml)。
# 产物输出到 workspace 根目录:func_soc_top.bit / .ltx /
# func_timing_summary.rpt / func_clock_timing_validation.txt

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

verify_chiplab
reset_chiplab_baseline
copy_student_rtl

# 对应 child.yml gen_func:打开 RUN_FUNC_TEST、关闭 RUN_PERF_TEST
sed -i '2s|.*|`define RUN_FUNC_TEST|' \
    "$CHIPLAB_DIR/chip/soc_demo/nscscc-team/soc_config.vh"
sed -i '3s|.*|// `define RUN_PERF_TEST|' \
    "$CHIPLAB_DIR/chip/soc_demo/nscscc-team/soc_config.vh"

cd "$CHIPLAB_DIR/fpga/nscscc-team/run_vivado"
vivado_batch create_project.tcl
# 本地适配:launch_runs 的批量 IP 生成在本机卡 mig_axi_32 的
# updateAllModelParams,bit.tcl 前单独预生成 mig(见 pregen_mig.tcl)。
# vivado_batch 不转换脚本路径,这里先转成 Windows 形式。
vivado_batch "$(cygpath -m "$SCRIPT_DIR/pregen_mig.tcl")"
if ! vivado_batch bit.tcl func; then
    report_vivado_failure func \
        project/loongson.runs/impl_1/clock_timing_validation.txt \
        project/loongson.runs/impl_1/timing_summary.rpt
    exit 1
fi

cp project/loongson.runs/impl_1/soc_top.bit ../../../../func_soc_top.bit
cp project/loongson.runs/impl_1/soc_top.ltx ../../../../func_soc_top.ltx
cp project/loongson.runs/impl_1/timing_summary.rpt ../../../../func_timing_summary.rpt || true
cp project/loongson.runs/impl_1/clock_timing_validation.txt ../../../../func_clock_timing_validation.txt

echo "gen_func done:"
cat "$WORKSPACE_DIR/func_clock_timing_validation.txt"
