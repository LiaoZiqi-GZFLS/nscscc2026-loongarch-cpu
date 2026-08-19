#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-/home/cjy/chiplab/toolchains/loongarch32r-linux-gnusf-2022-05-20/bin}"
JOBS="${BUILD_JOBS:-2}"
export PATH="$TOOLCHAIN_BIN:$PATH"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

check_layout() {
    for path in \
        .gitlab-ci.yml \
        Readme.md \
        design.pdf \
        score.xlsx \
        src/perf_clock.json \
        src/mycpu/core_top.v \
        src/mycpu/mycpu_top.v; do
        [[ -e "$ROOT_DIR/$path" ]] || die "required submission file is missing: $path"
    done

    python3 - "$ROOT_DIR/src/perf_clock.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    clock = json.load(stream).get("cpu_clk_mhz")
if not isinstance(clock, (int, float)) or not 10 <= clock <= 200:
    raise SystemExit(f"cpu_clk_mhz must be between 10 and 200, got {clock!r}")
print(f"cpu_clk_mhz={clock}")
PY

    grep -q '^module core_top' "$ROOT_DIR/src/mycpu/core_top.v" || die 'core_top module not found'
    grep -q '^module mycpu_top' "$ROOT_DIR/src/mycpu/mycpu_top.v" || die 'mycpu_top module not found'
}

build_boot() {
    require_command loongarch32r-linux-gnusf-gcc
    make -C "$ROOT_DIR/sw/boot" clean all check CROSS_COMPILE=loongarch32r-linux-gnusf-
}

build_ucore() {
    require_command loongarch32r-linux-gnusf-gcc
    TC=$(dirname "$TOOLCHAIN_BIN") "$ROOT_DIR/sw/ucore/build.sh"
}

build_linux() {
    require_command loongarch32r-linux-gnusf-gcc
    CROSS_COMPILE=loongarch32r-linux-gnusf- JOBS="$JOBS" \
        "$ROOT_DIR/sw/linux/build.sh" board-16m "$ROOT_DIR/.ci-work/linux"
}

check_vivado() {
    require_command vivado
    mkdir -p "$ROOT_DIR/.ci-work"
    vivado -mode batch -nolog -nojournal \
        -source "$ROOT_DIR/ci/vivado-check.tcl" \
        -tclargs "$ROOT_DIR" "$ROOT_DIR/.ci-work/vivado"
}

case "${1:-quick}" in
    layout)
        check_layout
        ;;
    boot)
        check_layout
        build_boot
        ;;
    vivado)
        check_layout
        check_vivado
        ;;
    ucore)
        check_layout
        build_ucore
        ;;
    linux)
        check_layout
        build_linux
        ;;
    quick)
        check_layout
        build_boot
        ;;
    *)
        die "usage: $0 {layout|boot|vivado|ucore|linux|quick}"
        ;;
esac
