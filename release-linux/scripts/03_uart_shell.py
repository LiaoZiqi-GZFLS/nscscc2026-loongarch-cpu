#!/usr/bin/env python3
"""03_uart_shell.py —— 交互式串口终端，用于操作板上 Linux shell。

用法:
    python 03_uart_shell.py               # 默认 COM3 115200
    python 03_uart_shell.py COM5          # 指定串口
    python 03_uart_shell.py COM3 --log run.log

按键直接发送给板子；Ctrl-] 退出终端（不影响板子运行）。
Windows 下依赖 pyserial:  pip install pyserial
"""
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial:  pip install pyserial")

PORT = "COM3"
BAUD = 115200
LOG = None

args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--log":
        LOG = args[i + 1]
        i += 2
    elif args[i] == "--baud":
        BAUD = int(args[i + 1])
        i += 2
    else:
        PORT = args[i]
        i += 1

ser = serial.Serial(PORT, BAUD, timeout=0.1)
log = open(LOG, "ab") if LOG else None
stop = threading.Event()


def reader():
    """把板子输出写到 stdout（并可选写日志）。"""
    while not stop.is_set():
        try:
            data = ser.read(4096)
        except Exception:
            break
        if data:
            if log:
                log.write(data)
                log.flush()
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()


threading.Thread(target=reader, daemon=True).start()

print(f"[已连接 {PORT} @ {BAUD} 8N1 —— Ctrl-] 退出]", flush=True)

# Windows: 逐键读取，回车转 \r，Ctrl-] 退出
try:
    import msvcrt

    while True:
        if msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch == b"\x1d":  # Ctrl-]
                break
            if ch == b"\r":
                ch = b"\r"
            elif ch == b"\x00" or ch == b"\xe0":  # 功能键前缀，丢弃后续
                msvcrt.getch()
                continue
            ser.write(ch)
            ser.flush()
        else:
            time.sleep(0.01)
except ImportError:
    # 非 Windows: 行模式
    try:
        for line in sys.stdin:
            ser.write(line.rstrip("\n").encode() + b"\r")
            ser.flush()
    except KeyboardInterrupt:
        pass
except KeyboardInterrupt:
    pass

stop.set()
time.sleep(0.3)
if log:
    log.close()
ser.close()
print("\n[已断开]")
