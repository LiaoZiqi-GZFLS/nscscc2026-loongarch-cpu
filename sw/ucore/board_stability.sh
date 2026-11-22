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
HW_SERVER_URL=${HW_SERVER_URL:-auto}
LOG_DIR=${LOG_DIR:-$ROOT/logs/ucore-board-$(date +%Y%m%d-%H%M%S)}
BIT=${BIT:-$ROOT/bit/sys_test/bit/sys_soc_top_100mhz.bit}

mkdir -p "$LOG_DIR"
local_hw_server_pid=

cleanup() {
    if [ -n "$local_hw_server_pid" ]; then
        kill "$local_hw_server_pid" 2>/dev/null || true
        wait "$local_hw_server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

run_logged() {
    log=$1
    shift
    pipe="$log.pipe.$$"
    rm -f "$pipe"
    mkfifo "$pipe"
    tee "$log" <"$pipe" &
    tee_pid=$!
    if "$@" >"$pipe" 2>&1; then
        status=0
    else
        status=$?
    fi
    wait "$tee_pid" 2>/dev/null || true
    rm -f "$pipe"
    return "$status"
}

run_vivado_logged() {
    log=$1
    shift
    pipe="$log.pipe.$$"
    rm -f "$pipe"
    mkfifo "$pipe"
    tee "$log" <"$pipe" | grep --line-buffered -E \
        '^(INFO: \[Labtools 27-(2285|2302|3164)|WARNING:|ERROR:|SERVERS=|TARGETS=|DEVICES=|PROGRAM_|VERIFY |UCORE_)' &
    display_pid=$!
    if "$@" >"$pipe" 2>&1; then
        status=0
    else
        status=$?
    fi
    wait "$display_pid" 2>/dev/null || true
    rm -f "$pipe"
    return "$status"
}

if [ "$HW_SERVER_URL" = auto ]; then
    if timeout 1 bash -c '</dev/tcp/localhost/3122' 2>/dev/null; then
        HW_SERVER_URL=localhost:3122
    else
        HW_SERVER_URL=localhost:3122
    fi
fi

case "$HW_SERVER_URL" in
    localhost:*|127.0.0.1:*)
      HW_SERVER_HOST=${HW_SERVER_URL%:*}
      HW_SERVER_PORT=${HW_SERVER_URL##*:}
      if ! timeout 1 bash -c "</dev/tcp/$HW_SERVER_HOST/$HW_SERVER_PORT" 2>/dev/null; then
          echo "Starting local hw_server at $HW_SERVER_URL"
          "$HW_SERVER" -d -s "tcp::$HW_SERVER_PORT" >"$LOG_DIR/hw-server.log" 2>&1 &
          local_hw_server_pid=$!
          ready=0
          for delay in 1 1 1 1 1; do
              sleep "$delay"
              if timeout 1 bash -c "</dev/tcp/$HW_SERVER_HOST/$HW_SERVER_PORT" 2>/dev/null; then
                  ready=1
                  break
              fi
              kill -0 "$local_hw_server_pid" 2>/dev/null || break
          done
          if [ "$ready" -ne 1 ]; then
              echo "Local hw_server failed; see $LOG_DIR/hw-server.log" >&2
              exit 1
          fi
      else
          echo "Using local hw_server at $HW_SERVER_URL"
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
    echo "Programming bitstream once..."
    if ! run_vivado_logged "$LOG_DIR/program-bit.log" env BIT_FILE="$BIT" \
        HW_SERVER_URL="$HW_SERVER_URL" "$VIVADO" -mode batch -nojournal -nolog \
        -source "$ROOT/program_current_hw.tcl"; then
        echo "Bit programming failed; see $LOG_DIR/program-bit.log" >&2
        exit 1
    fi
    sleep 3
fi

echo "Building uCore..."
if ! run_logged "$LOG_DIR/build.log" sh ./build.sh; then
    echo "uCore build failed; see $LOG_DIR/build.log" >&2
    exit 1
fi

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
        echo "round $round: programming bitstream..."
        if ! run_vivado_logged "$program_log" env BIT_FILE="$BIT" \
            HW_SERVER_URL="$HW_SERVER_URL" "$VIVADO" -mode batch -nojournal -nolog \
            -source "$ROOT/program_current_hw.tcl"; then
            echo "round $round: FAIL (bit programming); see $program_log"
            round=$((round + 1))
            continue
        fi
        sleep 3
    fi
    stty -F "$UART" 115200 cs8 -cstopb -parenb clocal raw -echo
    timeout 1 dd if="$UART" of=/dev/null bs=1 status=none 2>/dev/null || true
    echo "round $round: capturing live UART from $UART..."
    tee "$uart_log" <"$UART" &
    reader=$!
    sleep 1
    echo "round $round: downloading uCore and releasing CPU..."
    if ! run_vivado_logged "$vivado_log" env UCORE_IMAGE="$PWD/out/ucore.bin" \
        HW_SERVER_URL="$HW_SERVER_URL" "$VIVADO" -mode batch -nojournal -nolog \
        -source "$PWD/tools/load_ucore_stability.tcl"; then
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
        if [ ! -s "$uart_log" ]; then
            echo "round $round: UART log is empty; check the selected VID:PID, permissions, cable, and competing serial readers"
            ls -l "$UART" 2>/dev/null || true
            command -v lsof >/dev/null 2>&1 && lsof "$UART" 2>/dev/null || true
        fi
    fi
    round=$((round + 1))
done

printf 'board stability: %d/%d passed\n' "$passed" "$ROUNDS" | tee "$LOG_DIR/summary.txt"
[ "$passed" -eq "$ROUNDS" ]
