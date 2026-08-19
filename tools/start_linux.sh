#!/bin/sh
# One-command board startup: validate RAM, load both images, release CPU, attach UART.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
VARIANT=${VARIANT:-board-16m}
PORT=${UART_PORT:-/dev/ttyUSB0}
BAUD=${UART_BAUD:-115200}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-45}
LOG=${UART_LOG:-$ROOT/logs/linux-uart-live.log}
VIVADO=${VIVADO:-vivado}
HW_LOAD="$ROOT/load_linux_hw.tcl"
HW_RELEASE="$ROOT/release_cpu_hw.tcl"
HW_PROGRAM="$ROOT/program_current_hw.tcl"

usage() {
  printf '%s\n' "Usage: $0 [--port DEVICE] [--variant board-16m] [--log FILE] [--boot-timeout SEC] [--no-console] [--no-program]"
  printf '%s\n' "Environment: UART_PORT, UART_BAUD, UART_LOG, BOOT_TIMEOUT, VIVADO, RESERVE"
}

NO_CONSOLE=0
NO_PROGRAM=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT=${2:?missing device after --port}; shift 2 ;;
    --variant) VARIANT=${2:?missing variant after --variant}; shift 2 ;;
    --log) LOG=${2:?missing log path after --log}; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT=${2:?missing seconds after --boot-timeout}; shift 2 ;;
    --no-console) NO_CONSOLE=1; shift ;;
    --no-program) NO_PROGRAM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$VARIANT" = board-16m ] || { echo "only board-16m is supported by the JTAG loader" >&2; exit 2; }
[ -x "$ROOT/sw/linux/check_memory.sh" ] || chmod +x "$ROOT/sw/linux/check_memory.sh"
"$ROOT/sw/linux/check_memory.sh" "$VARIANT"
[ -f "$HW_LOAD" ] && [ -f "$HW_RELEASE" ] || { echo "JTAG TCL scripts are missing" >&2; exit 1; }
command -v "$VIVADO" >/dev/null 2>&1 || { echo "Vivado not found: $VIVADO" >&2; exit 1; }
if [ "$NO_CONSOLE" -eq 0 ]; then
  [ -c "$PORT" ] || { echo "UART device not found: $PORT" >&2; exit 1; }
fi

echo "Loading Linux images through Vivado hw_server..."
if [ "$NO_PROGRAM" -eq 0 ]; then
  [ -f "$HW_PROGRAM" ] || { echo "FPGA programming TCL script is missing" >&2; exit 1; }
  echo "Programming FPGA for a cold CPU/cache reset..."
  "$VIVADO" -mode batch -source "$HW_PROGRAM"
fi
"$VIVADO" -mode batch -source "$HW_LOAD"

if [ "$NO_CONSOLE" -eq 0 ]; then
  echo "Attaching UART, then releasing CPU reset..."
  mkdir -p "$(dirname "$LOG")"
  "$VIVADO" -mode batch -source "$HW_RELEASE" &
  exec python3 "$HERE/uart_console.py" "$PORT" --baud "$BAUD" --log "$LOG" --boot-timeout "$BOOT_TIMEOUT"
fi
echo "Releasing CPU reset..."
"$VIVADO" -mode batch -source "$HW_RELEASE"
echo "Linux started. Attach UART with: python3 $HERE/uart_console.py $PORT --baud $BAUD"
