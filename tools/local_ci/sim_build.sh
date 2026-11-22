#!/usr/bin/env bash
# iverilog 功能仿真构建+运行(团队 SoC SIMULATION 模式,BRAM 直载程序)
# 用法:sim_build.sh <bin文件> <周期数上限(轮)> [输出日志路径]
set -euo pipefail

WORKSPACE="D:/code/Vivado/Loongarch_workspace"
CHIPLAB="$WORKSPACE/chiplab"
SOC_DIR="$CHIPLAB/chip/soc_demo/nscscc-team"
RUNVIV="$CHIPLAB/fpga/nscscc-team/run_vivado"
IP_DIR="$SOC_DIR/xilinx_ip"
IPSTATIC="$RUNVIV/.ip_user_files/ipstatic/gen"
XPM_DIR="C:/Xilinx/Vivado/2023.2/data/ip/xpm"
RUN_DIR="$WORKSPACE/s/i/m/r/w"

BIN_FILE="$1"
CYCLES_LIMIT="$2"
LOG_FILE="${3:-$WORKSPACE/sim_run.log}"

[ -f "$BIN_FILE" ] || { echo "ERROR: bin not found: $BIN_FILE" >&2; exit 1; }

mapfile -t SOC_SRC < <(find "$SOC_DIR" -name "*.v" -not -path "*/xilinx_ip/*" -not -path "*/uart_debug/testbench/*")

# IP 行为级模型(Xilinx IP 仿真文件)
IP_MODELS=(
    "$IP_DIR/jtag_axi/gen/sim/jtag_axi.v"
    "$IP_DIR/axi_crossbar_2x3/gen/sim/axi_crossbar_2x3.v"
    "$WORKSPACE/sim_ip_models/vio_stub/vio_0.v"
    "$IP_DIR/jtag_axi/gen/gen/b140/hdl/jtag_axi_v1_2_rfs.v"
    "$IP_DIR/jtag_axi/gen/gen/a29c/hdl/xsdbs_v1_0_vl_rfs.v"
    "$IP_DIR/jtag_axi/gen/gen/e2ba/hdl/ltlib_v1_0_vl_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/10ab/hdl/generic_baseblocks_v2_1_vl_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/279e/hdl/axi_data_fifo_v2_1_vl_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ac72/hdl/fifo_generator_v13_2_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ac72/simulation/fifo_generator_vlog_beh.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ec67/hdl/axi_infrastructure_v1_1_vl_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/fb47/hdl/axi_crossbar_v2_1_vl_rfs.v"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ff9f/hdl/axi_register_slice_v2_1_vl_rfs.v"
    "$XPM_DIR/xpm_cdc/hdl/xpm_cdc.sv"
    "$XPM_DIR/xpm_memory/hdl/xpm_memory.sv"
    "$RUNVIV/project/loongson.cache/ip/2023.2/b/7/b742c4ebc028e7b2/multiplier_sim_netlist.v"
    "$RUNVIV/project/loongson.cache/ip/2023.2/b/7/b742c4ebc028e7b2/multiplier_stub.v"
)

CPU_SRC=("$CHIPLAB/IP/myCPU/mycpu_top.v" "$CHIPLAB/IP/myCPU/core_top.v")
TB_SRC="$CHIPLAB/fpga/nscscc-team/testbench/mycpu_tb.sv"

INCS=(
    "$SOC_DIR"
    "$IP_DIR/jtag_axi/gen/gen/e2ba/hdl/verilog"
    "$IP_DIR/jtag_axi/gen/gen/a29c/hdl/verilog"
    "$IP_DIR/vio/hdl/verilog"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/279e/hdl/verilog"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ac72/hdl/verilog"
    "$IP_DIR/axi_crossbar_2x3/gen/gen/ec67/hdl/verilog"
    "$XPM_DIR/xpm_cdc/hdl"
    "$XPM_DIR/xpm_memory/hdl"
)
# 相对 include(如 ../soc_config.vh)按 -I 目录解析:把所有源文件所在目录也加入
declare -A SEEN_DIRS
INC_ARGS=()
for d in "${INCS[@]}" "${SOC_SRC[@]}" "${IP_MODELS[@]}" "${CPU_SRC[@]}" "$TB_SRC"; do
    dir="$d"
    [ -f "$d" ] && dir="$(dirname "$d")"
    if [ -d "$dir" ] && [ -z "${SEEN_DIRS[$dir]:-}" ]; then
        SEEN_DIRS[$dir]=1
        INC_ARGS+=(-I "$dir")
    fi
done

mkdir -p "$RUN_DIR"
iverilog -g2012 "${INC_ARGS[@]}" \
    -o "$RUN_DIR/sim.out" -s tb_top \
    "${SOC_SRC[@]}" "${IP_MODELS[@]}" "${CPU_SRC[@]}" "$TB_SRC" \
    > "$WORKSPACE/sim_compile.log" 2>&1 || true
if [ ! -f "$RUN_DIR/sim.out" ]; then
    echo "COMPILE FAILED (tail of sim_compile.log):"
    tail -30 "$WORKSPACE/sim_compile.log"
    exit 1
fi
echo "COMPILE OK ($(wc -l < "$WORKSPACE/sim_compile.log") log lines)"

cp "$BIN_FILE" "$WORKSPACE/inst_data.bin"
cd "$RUN_DIR"
./sim.out -l "$LOG_FILE" "$CYCLES_LIMIT" > /dev/null 2>&1 || true
echo "=== sim tail ==="
tail -40 "$LOG_FILE"
