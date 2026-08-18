#!/bin/sh
set -eu

cd "$(dirname "$0")"
VIVADO=${VIVADO:-vivado}
HW_SERVER=${HW_SERVER:-hw_server}
FUNC_BIT=${FUNC_BIT:-$PWD/bit/func_test/func_soc_top.bit}
FUNC_BIN=${FUNC_BIN:-/home/cjy/chiplab/software/examples/nscscc_func/obj/main.bin}
FUNC_LTX=${FUNC_LTX:-/home/cjy/T2026143250012561-build/artifacts/soc_top.ltx}
FUNC_TIMEOUT=${FUNC_TIMEOUT:-120}
FUNC_SWITCH=${FUNC_SWITCH:-FF}
LOG=${LOG:-$PWD/logs/chiplab-func-board-$(date +%Y%m%d-%H%M%S).log}

test -f "$FUNC_BIT" || { echo "Missing bitstream: $FUNC_BIT" >&2; exit 1; }
test -f "$FUNC_BIN" || { echo "Missing function-test image: $FUNC_BIN" >&2; exit 1; }
test -f "$FUNC_LTX" || { echo "Missing probes file: $FUNC_LTX" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

if ! pgrep -x hw_server >/dev/null 2>&1; then
    "$HW_SERVER" -d -s tcp::3121
    sleep 1
fi

echo "FUNC_BIT=$FUNC_BIT"
echo "FUNC_BIN=$FUNC_BIN"
echo "FUNC_LTX=$FUNC_LTX"
echo "FUNC_SWITCH=$FUNC_SWITCH FUNC_TIMEOUT=$FUNC_TIMEOUT LOG=$LOG"

if FUNC_BIT="$FUNC_BIT" FUNC_BIN="$FUNC_BIN" FUNC_LTX="$FUNC_LTX" \
    FUNC_SWITCH="$FUNC_SWITCH" FUNC_TIMEOUT="$FUNC_TIMEOUT" \
    "$VIVADO" -mode batch -nojournal -nolog -source "$PWD/tools/chiplab_func_board.tcl" \
    >"$LOG" 2>&1; then
    grep -E '^(IMAGE_VERIFY|FUNC_IMAGE_LOADED|FUNC_CPU_RELEASED|NUM_DATA|BOARD_STATUS|CHIPLAB_FUNC_PASS)' "$LOG"
else
    grep -E '^(IMAGE_VERIFY|FUNC_IMAGE_LOADED|FUNC_CPU_RELEASED|NUM_DATA|BOARD_STATUS|ERROR)' "$LOG" || true
    echo "Chiplab function board test failed; see $LOG" >&2
    exit 1
fi
