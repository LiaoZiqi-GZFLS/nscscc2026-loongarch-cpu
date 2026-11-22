#!/bin/sh
set -eu

cd "$(dirname "$0")"

HW_SERVER_URL=${HW_SERVER_URL:-localhost:3122}
HW_SERVER=${HW_SERVER:-/tools/Xilinx/Vivado/2023.2/bin/hw_server}
UART=${UART:-auto}
PROGRAM_BIT=${PROGRAM_BIT:-each}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-45}
PICOCOM=${PICOCOM:-picocom}
HW_SERVER_LOG=${HW_SERVER_LOG:-/tmp/ucore-hw-server.log}

server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

usb_ids_for_tty() {
    path=$(readlink -f "/sys/class/tty/$(basename "$1")/device")
    while [ "$path" != / ]; do
        if [ -f "$path/idVendor" ] && [ -f "$path/idProduct" ]; then
            printf '%s:%s\n' "$(cat "$path/idVendor")" "$(cat "$path/idProduct")"
            return 0
        fi
        path=$(dirname "$path")
    done
    return 1
}

find_uart() {
    for port in /dev/ttyUSB*; do
        [ -e "$port" ] || continue
        [ "$(usb_ids_for_tty "$port" 2>/dev/null || true)" = 0403:6001 ] || continue
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

find_jtag_usb() {
    for device in /sys/bus/usb/devices/*; do
        [ -f "$device/idVendor" ] || continue
        [ "$(cat "$device/idVendor")" = 0403 ] || continue
        [ "$(cat "$device/idProduct")" = 6010 ] || continue
        bus=$(printf '%03d' "$(cat "$device/busnum")")
        dev=$(printf '%03d' "$(cat "$device/devnum")")
        printf '/dev/bus/usb/%s/%s\n' "$bus" "$dev"
        return 0
    done
    return 1
}

tcp_ready() {
    timeout 1 bash -c "</dev/tcp/$1/$2" 2>/dev/null
}

if [ "$UART" = auto ]; then
    UART=$(find_uart) || {
        echo "Independent UART 0403:6001 not found." >&2
        echo "Attach it to WSL with usbipd, or set UART=/dev/ttyUSBx." >&2
        exit 1
    }
fi

if [ ! -r "$UART" ] || [ ! -w "$UART" ]; then
    echo "Granting access to $UART"
    sudo chmod 666 "$UART"
fi

case "$HW_SERVER_URL" in
    localhost:*|127.0.0.1:*)
        server_host=${HW_SERVER_URL%:*}
        server_port=${HW_SERVER_URL##*:}
        if ! tcp_ready "$server_host" "$server_port"; then
            jtag_usb=$(find_jtag_usb) || {
                echo "JTAG USB device 0403:6010 not found." >&2
                echo "Attach it to WSL with usbipd before running this script." >&2
                exit 1
            }
            if [ ! -r "$jtag_usb" ] || [ ! -w "$jtag_usb" ]; then
                echo "Granting access to $jtag_usb"
                sudo chmod 666 "$jtag_usb"
            fi
            echo "Starting local hw_server at $HW_SERVER_URL"
            "$HW_SERVER" -d -s "tcp::$server_port" >"$HW_SERVER_LOG" 2>&1 &
            server_pid=$!
            ready=0
            for delay in 1 1 1 1 1; do
                sleep "$delay"
                if tcp_ready "$server_host" "$server_port"; then
                    ready=1
                    break
                fi
                kill -0 "$server_pid" 2>/dev/null || break
            done
            if [ "$ready" -ne 1 ]; then
                echo "hw_server failed to listen at $HW_SERVER_URL; see $HW_SERVER_LOG" >&2
                exit 1
            fi
        else
            echo "Using existing hw_server at $HW_SERVER_URL"
        fi
        ;;
    *)
        echo "Using remote hw_server at $HW_SERVER_URL"
        ;;
esac

echo "UART=$UART"
echo "Programming and booting uCore..."
HW_SERVER_URL="$HW_SERVER_URL" \
UART="$UART" \
PROGRAM_BIT="$PROGRAM_BIT" \
ROUNDS=1 \
BOOT_TIMEOUT="$BOOT_TIMEOUT" \
sh ./board_stability.sh

command -v "$PICOCOM" >/dev/null 2>&1 || {
    echo "uCore boot passed, but picocom is not installed." >&2
    echo "Install it with: sudo apt-get install picocom" >&2
    exit 1
}

echo "Opening uCore shell on $UART (115200 8N1)."
echo "Exit picocom with Ctrl-A, then Ctrl-X."
"$PICOCOM" -b 115200 --databits 8 --parity n --stopbits 1 \
    --imap delbs "$UART"
