#!/usr/bin/env bash
# 2026 NSCSCC Team CI 本地部署公共库。
# 复刻 nscscc-team-ci/child.yml 中 gen_func/gen_perf Job 的环境与检查,
# 平台:Windows + Git Bash + Vivado 2023.2。

set -euo pipefail

# ---- 环境变量(对应 child.yml 的 variables)----
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHIPLAB_DIR="$WORKSPACE_DIR/chiplab"
TEAM_REPO_DIR="$WORKSPACE_DIR/T2026143250012561"
EXPECTED_CHIPLAB_COMMIT="68c20a539e2be8a05300e714296f5fda8373ee80"
VIVADO_BAT="/c/Xilinx/Vivado/2023.2/bin/vivado.bat"

# ---- chiplab 基线校验(对应 CI before_script 的 commit 检查)----
# CI 用 git archive 从只读快照导出;本地直接使用 clone 出的工作目录,
# 因此只校验 HEAD,并把脚本会修改的唯一跟踪文件 soc_config.vh 靠 git 复位。
verify_chiplab() {
    if [ ! -d "$CHIPLAB_DIR/.git" ]; then
        echo "ERROR: chiplab repository not found: $CHIPLAB_DIR" >&2
        exit 1
    fi
    local actual_commit
    actual_commit="$(git -C "$CHIPLAB_DIR" rev-parse HEAD)"
    if [ "$actual_commit" != "$EXPECTED_CHIPLAB_COMMIT" ]; then
        echo "ERROR: unexpected chiplab commit" >&2
        echo "  expected: $EXPECTED_CHIPLAB_COMMIT" >&2
        echo "  actual:   $actual_commit" >&2
        exit 1
    fi
    echo "Verified chiplab repository at $actual_commit"
}

# ---- chiplab 基线复位 ----
# CI 每个 Job 从全新快照开始。本地复用同一工作目录,而 Vivado 构建会回写
# 跟踪文件(如 soc_config.vh、vio_0.xci)并产生未跟踪输出,因此每次运行前
# 将工作树整体复位到提交状态,等价于 CI 的全新快照。
# 提交状态即 perf 配置(RUN_PERF_TEST 打开、RUN_FUNC_TEST 注释)。
reset_chiplab_baseline() {
    git -C "$CHIPLAB_DIR" checkout -- .
    # vivado.jou 是每次运行重新生成的临时日志(未跟踪),可能被退出进程的
    # 残留句柄锁住,排除出 clean;Vivado 进程退出后也可能残留短暂文件句柄
    # (git clean 报 Invalid argument/Device busy),重试几次容忍瞬时锁。
    local attempt
    for attempt in 1 2 3; do
        if git -C "$CHIPLAB_DIR" clean -fd -e vivado.jou; then
            return 0
        fi
        echo "WARNING: git clean failed (attempt $attempt/3), retrying..." >&2
        sleep 3
    done
    return 1
}

# ---- 学生 RTL 拷贝(对应 CI before_script 的 IP/myCPU 替换)----
copy_student_rtl() {
    if [ ! -d "$TEAM_REPO_DIR/src/mycpu" ]; then
        echo "ERROR: student RTL directory not found: $TEAM_REPO_DIR/src/mycpu" >&2
        exit 1
    fi
    rm -rf "$CHIPLAB_DIR/IP/myCPU"
    mkdir -p "$CHIPLAB_DIR/IP/myCPU"
    cp -a "$TEAM_REPO_DIR/src/mycpu/." "$CHIPLAB_DIR/IP/myCPU/"
    echo "Copied student RTL: $TEAM_REPO_DIR/src/mycpu -> $CHIPLAB_DIR/IP/myCPU"
}

# ---- Vivado batch 调用封装 ----
# 用法:vivado_batch <tcl脚本> [tclargs...]
# 绝对 POSIX 路径参数会转成 Windows 路径再传给 Vivado(与 CI 在 Linux 上
# 直接传路径等价);其余参数原样透传。必须已在 run_vivado 目录下调用。
vivado_batch() {
    local tcl_script="$1"
    shift
    local args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            /*) args+=("$(cygpath -m "$arg")") ;;
            *)  args+=("$arg") ;;
        esac
    done
    if [ "${#args[@]}" -gt 0 ]; then
        MSYS_NO_PATHCONV=1 "$VIVADO_BAT" -mode batch -source "$tcl_script" \
            -tclargs "${args[@]}"
    else
        MSYS_NO_PATHCONV=1 "$VIVADO_BAT" -mode batch -source "$tcl_script"
    fi
}

# ---- Vivado 失败报告(与 child.yml report_vivado_failure 一致)----
report_vivado_failure() {
    local build_kind="$1"
    local validation_source="$2"
    local timing_source="$3"
    local validation_artifact="$WORKSPACE_DIR/${build_kind}_clock_timing_validation.txt"
    local timing_artifact="$WORKSPACE_DIR/${build_kind}_timing_summary.rpt"

    if [ -f "$timing_source" ]; then
        cp "$timing_source" "$timing_artifact"
    fi
    if [ -f "$validation_source" ]; then
        cp "$validation_source" "$validation_artifact"
    fi

    printf '\033[1;31m%s\033[0m\n' \
        "================================================================" >&2
    if [ -s "$validation_artifact" ]; then
        local requested_cpu_mhz
        local actual_cpu_mhz
        local actual_sys_mhz
        local actual_ddr_mhz
        local setup_wns
        local hold_slack

        requested_cpu_mhz="$(sed -n 's/^requested_cpu_mhz=//p' "$validation_artifact")"
        actual_cpu_mhz="$(sed -n 's/^actual_cpu_mhz=//p' "$validation_artifact")"
        actual_sys_mhz="$(sed -n 's/^actual_sys_mhz=//p' "$validation_artifact")"
        actual_ddr_mhz="$(sed -n 's/^actual_ddr_mhz=//p' "$validation_artifact")"
        setup_wns="$(sed -n 's/^setup_wns_ns=//p' "$validation_artifact")"
        hold_slack="$(sed -n 's/^hold_wns_ns=//p' "$validation_artifact")"

        printf '\033[1;31mERROR: TIMING GATE FAILED [%s]\033[0m\n' \
            "$build_kind" >&2
        if [ -n "$requested_cpu_mhz" ]; then
            printf 'Requested CPU clock: %s MHz\n' "$requested_cpu_mhz" >&2
        fi
        printf 'Actual CPU clock:    %s MHz\n' "${actual_cpu_mhz:-unknown}" >&2
        printf 'System clock:        %s MHz\n' "${actual_sys_mhz:-unknown}" >&2
        printf 'DDR reference clock: %s MHz\n' "${actual_ddr_mhz:-unknown}" >&2
        if awk -v value="${setup_wns:-0}" 'BEGIN { exit !(value < 0) }'; then
            printf '\033[1;31mSetup WNS:            %s ns (required >= 0)\033[0m\n' \
                "${setup_wns:-unknown}" >&2
        else
            printf 'Setup WNS:            %s ns (required >= 0)\n' \
                "${setup_wns:-unknown}" >&2
        fi
        if awk -v value="${hold_slack:-0}" 'BEGIN { exit !(value < 0) }'; then
            printf '\033[1;31mHold slack:           %s ns (required >= 0)\033[0m\n' \
                "${hold_slack:-unknown}" >&2
        else
            printf 'Hold slack:           %s ns (required >= 0)\n' \
                "${hold_slack:-unknown}" >&2
        fi
        printf 'Bitstream rejected; FPGA programming was not started.\n' >&2
    else
        printf '\033[1;31mERROR: VIVADO BUILD FAILED BEFORE TIMING VALIDATION [%s]\033[0m\n' \
            "$build_kind" >&2
    fi
    printf 'Diagnostic artifacts are uploaded when available:\n' >&2
    printf '  %s\n' "$(basename "$validation_artifact")" >&2
    printf '  %s\n' "$(basename "$timing_artifact")" >&2
    printf '\033[1;31m%s\033[0m\n' \
        "================================================================" >&2
}
