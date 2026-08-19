#!/usr/bin/env python3
"""Small dependency-free UART console for the board's 16550 USB serial port."""
import argparse
import errno
import fcntl
import os
import select
import sys
import termios
import time
import tty


BAUD_RATES = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}


def main():
    parser = argparse.ArgumentParser(description="Interactive 115200 8N1 UART console with Linux boot monitoring")
    parser.add_argument("port", help="serial device, for example /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--log", help="also append received bytes to a log file")
    parser.add_argument("--boot-timeout", type=float, default=45.0,
                        help="report a boot stall after this many seconds (0 disables it)")
    parser.add_argument("--no-monitor", action="store_true",
                        help="disable Linux boot milestone monitoring")
    parser.add_argument("--receive-only", action="store_true",
                        help="capture UART without requiring an interactive terminal")
    args = parser.parse_args()

    if args.baud not in BAUD_RATES:
        parser.error("supported baud rates: %s" % ", ".join(map(str, BAUD_RATES)))

    log = open(args.log, "ab") if args.log else None
    stdin_fd = None
    serial_fd = None
    old = None
    try:
        serial_fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY)
        if hasattr(termios, "TIOCEXCL"):
            fcntl.ioctl(serial_fd, termios.TIOCEXCL)
        attrs = termios.tcgetattr(serial_fd)
        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0
        attrs[4] = BAUD_RATES[args.baud]
        attrs[5] = BAUD_RATES[args.baud]
        attrs[6][termios.VMIN] = 1
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(serial_fd, termios.TCSANOW, attrs)
        termios.tcflush(serial_fd, termios.TCIOFLUSH)

        if not args.receive_only:
            stdin_fd = sys.stdin.fileno()
            if not os.isatty(stdin_fd):
                raise OSError("stdin must be a terminal for interactive UART mode")
            old = termios.tcgetattr(stdin_fd)
            tty.setraw(stdin_fd)
        mode = "receive-only" if args.receive_only else "Ctrl-] exits"
        print("UART connected: %s %d 8N1 (%s)" % (args.port, args.baud, mode), file=sys.stderr)
        milestones = (
            ("Linux version", "kernel banner"),
            ("Memory:", "memory setup"),
            ("serial: ttyS0", "UART driver"),
            ("Run /init as init process", "userspace handoff"),
            ("T2026143250012561 LA32R", "Linux userspace banner"),
        )
        seen = set()
        monitor_started = time.monotonic()
        last_rx = monitor_started
        stall_reported = False
        line_buffer = b""
        while True:
            inputs = [serial_fd] if args.receive_only else [stdin_fd, serial_fd]
            readable, _, _ = select.select(inputs, [], [], 0.25)
            if stdin_fd is not None and stdin_fd in readable:
                data = os.read(stdin_fd, 1024)
                if not data or b"\x1d" in data:
                    break
                os.write(serial_fd, data)
            if serial_fd in readable:
                try:
                    data = os.read(serial_fd, 4096)
                except OSError as exc:
                    if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                        raise
                    data = b""
                if data:
                    last_rx = time.monotonic()
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    if log:
                        log.write(data)
                        log.flush()
                    if not args.no_monitor:
                        line_buffer = (line_buffer + data)[-8192:]
                        lines = line_buffer.split(b"\n")
                        for line in lines[:-1]:
                            text = line.decode("utf-8", "replace")
                            for marker, name in milestones:
                                if marker in text and name not in seen:
                                    seen.add(name)
                                    print("[boot] %s: %s" % (name, text.strip()), file=sys.stderr)
                        line_buffer = lines[-1]
            if (not args.no_monitor and args.boot_timeout > 0 and
                    not stall_reported and "userspace banner" not in seen and
                    time.monotonic() - monitor_started >= args.boot_timeout):
                stall_reported = True
                print("[boot] timeout: no interactive shell after %.1fs; last UART activity %.1fs ago" %
                      (args.boot_timeout, time.monotonic() - last_rx), file=sys.stderr)
    except (KeyboardInterrupt, OSError) as exc:
        print("\nUART stopped: %s" % exc, file=sys.stderr)
    finally:
        if old is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old)
        if log:
            log.close()
        if serial_fd is not None:
            os.close(serial_fd)


if __name__ == "__main__":
    main()
