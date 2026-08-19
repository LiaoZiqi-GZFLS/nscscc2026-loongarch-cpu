#!/bin/sh
set -eu

cd "$(dirname "$0")"
ROOT=$(CDPATH= cd ../.. && pwd)
ROUNDS=${ROUNDS:-3}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-30}
UART=${UART:-auto}
PROGRAM_BIT=${PROGRAM_BIT:-each}
VIVADO=${VIVADO:-vivado}
HW_SERVER=${HW_SERVER:-hw_server}
HW_SERVER_URL=${HW_SERVER_URL:-localhost:3121}
LOG_DIR=${LOG_DIR:-$ROOT/logs/ucore-board-$(date +%Y%m%d-%H%M%S)}
BIT=${BIT:-$ROOT/bit/sys_test/bit/sys_soc_top_100mhz.bit}

mkdir -p "$LOG_DIR"

case "$HW_SERVER_URL" in
    localhost:3121|127.0.0.1:3121)
      if ! pgrep -x hw_server >/dev/null 2>&1; then
          "$HW_SERVER" -d -s tcp::3121
          sleep 1
      fi
      ;;
    *)
      echo "Using remote hw_server at $HW_SERVER_URL"
      HW_SERVER_HOST=${HW_SERVER_URL%:*}
      HW_SERVER_PORT=${HW_SERVER_URL##*:}
      if ! timeout 2 bash -c "</dev/tcp/$HW_SERVER_HOST/$HW_SERVER_PORT" 2>/dev/null; then
          echo "Cannot reach remote hw_server at $HW_SERVER_URL" >&2
          echo "Check Windows hw_server, firewall, and WSL host address" >&2
          exit 1
      fi
      echo "hw_server reachable: $HW_SERVER_URL"
      ;;
esac

if [ "$PROGRAM_BIT" = once ]; then
    test -f "$BIT"
    BIT_FILE="$BIT" "$VIVADO" -mode batch -nojournal -nolog \
        -source "$ROOT/program_current_hw.tcl" >"$LOG_DIR/program-bit.log" 2>&1
    sleep 3
fi

sh ./build.sh >"$LOG_DIR/build.log" 2>&1

probe_uart() {
    for port in /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$port" ] || continue
        stty -F "$port" 115200 cs8 -cstopb -parenb raw -echo
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

if [ "$UART" = auto ]; then
    UART=$(probe_uart) || {
        echo "No UART device found; set UART=/dev/ttyUSBx" >&2
        exit 1
    }
fi
test -r "$UART" && test -w "$UART"
echo "UART=$UART ROUNDS=$ROUNDS BOOT_TIMEOUT=$BOOT_TIMEOUT LOG_DIR=$LOG_DIR"

passed=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
    uart_log="$LOG_DIR/round-$round-uart.log"
    vivado_log="$LOG_DIR/round-$round-vivado.log"
    if [ "$PROGRAM_BIT" = each ]; then
        program_log="$LOG_DIR/round-$round-program-bit.log"
        if ! BIT_FILE="$BIT" HW_SERVER_URL="$HW_SERVER_URL" "$VIVADO" -mode batch -nojournal -nolog \
            -source "$ROOT/program_current_hw.tcl" >"$program_log" 2>&1; then
            echo "round $round: FAIL (bit programming); see $program_log"
            round=$((round + 1))
            continue
        fi
        sleep 3
    fi
    stty -F "$UART" 115200 cs8 -cstopb -parenb clocal raw -echo
    timeout 1 dd if="$UART" of=/dev/null bs=1 status=none 2>/dev/null || true
    dd if="$UART" of="$uart_log" bs=1 status=none 2>/dev/null &
    reader=$!
    sleep 1
    if ! UCORE_IMAGE="$PWD/out/ucore.bin" HW_SERVER_URL="$HW_SERVER_URL" "$VIVADO" -mode batch -nojournal -nolog \
        -source "$PWD/tools/load_ucore_stability.tcl" >"$vivado_log" 2>&1; then
        kill "$reader" 2>/dev/null || true
        wait "$reader" 2>/dev/null || true
        echo "round $round: FAIL (Vivado/JTAG); see $vivado_log"
        round=$((round + 1))
        continue
    fi
    elapsed=0
    while [ "$elapsed" -lt "$BOOT_TIMEOUT" ]; do
        if grep -q "user sh is running\|kernel panic\|Trap in kernel" "$uart_log"; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    kill "$reader" 2>/dev/null || true
    wait "$reader" 2>/dev/null || true
    if grep -q "check_boot_pgdir() succeeded" "$uart_log" && \
       grep -q "user sh is running" "$uart_log" && \
       ! grep -q "kernel panic\|Trap in kernel" "$uart_log"; then
        passed=$((passed + 1))
        echo "round $round: PASS"
    else
        echo "round $round: FAIL (boot markers missing); see $uart_log"
    fi
    round=$((round + 1))
done

printf 'board stability: %d/%d passed\n' "$passed" "$ROUNDS" | tee "$LOG_DIR/summary.txt"
[ "$passed" -eq "$ROUNDS" ]
