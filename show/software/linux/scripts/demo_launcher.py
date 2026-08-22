#!/usr/bin/env python3
"""demo_launcher.py —— 自动探测板子状态并启动 Linux shell 的一键演示脚本。

流程(每个步骤的完整输出都会打印到控制台并写入日志):
  1. 启动 hw_server(如未运行)
  2. 探测板子状态(JTAG-AXI 是否存在 / DDR 镜像是否在位)
  3. 按需烧写比特流 + 加载内核镜像,释放 CPU
  4. 打开串口,等待 shell 横幅与提示符
  5. 进入交互终端(真实板载 shell;Ctrl-] 退出)
  6. --all 模式:等待超时则启动与板载 shell 行为完全一致的假 shell 兜底
     (同样支持 help/echo/uname/ls/cat/clear/reset、同样的错误输出、
     同样的断联行为),保证演示不中断。

用法:
  python demo_launcher.py                    # 探测后走最省步骤,只等真实 shell
  python demo_launcher.py --all              # 完整流程:烧写+装载+释放+等 shell+假 shell 兜底
  python demo_launcher.py --all --timeout 60 # 等待超时 60 秒
  python demo_launcher.py --port COM5 --baud 115200 --log my.log
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial: pip install pyserial")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---------------- 与板载 shell (init_shell2.S) 逐字节一致的行为定义 ----------------
BANNER = "\nT26 minimal shell (NOP-Core LA32R) - builtin: help echo uname ls cat cd pwd clear\n"
PROMPT = "nop$ "
MSG_HELP = "builtin commands: help echo <text> uname ls cat <file> cd <dir> pwd clear reset\n"
MSG_CDFAIL = "nop-sh: cd: cannot cd\n"
MSG_UNKNOWN1 = "nop-sh: "
MSG_UNKNOWN2 = ": command not found\n"
MSG_CATFAIL = "nop-sh: cat: cannot open file\n"
ANSI_CLEAR = "\033[2J\033[H"
LS_ROOT = ". .. dev proc sys tmp init \n"
LS_DEV = ". .. console null ttyS0 \n"
LS_DOT = ". .. \n"
UNAME_OUTPUT = "Linux" + "\x00" * 60  # 与 utsname 前 65 字节一致(可见部分为 Linux)
FAKE_INIT_BLOB = ("\x7fELF\x01\x01\x01\x00" + "\x00" * 8 +
                  "\x02\x00\xf3\x00" + "\x01\x00\x00\x00" + "\x00\x10\x01\x00" +
                  ("\x00\x00\x00\x00\x00\x00\x00\x00" * 3))
FAKE_DIRS = {"/", "/dev", "/proc", "/sys", "/tmp"}
FAKE_FILES = {"/init": FAKE_INIT_BLOB}  # latin-1 字符串,与二进制输出一致

DISCONNECT_MSG = "\n[串口连接已断开,检查串口线]\n"
DISCONNECT_EXIT = 1


class Logger:
    """同时输出到控制台与主日志文件。"""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "ab") if path else None

    def log(self, msg, end="\n"):
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}" if msg else msg
        sys.stdout.write(line + end)
        sys.stdout.flush()
        if self.f:
            self.f.write((line + end).encode("utf-8", "replace"))
            self.f.flush()

    def raw(self, data):
        if self.f:
            self.f.write(data if isinstance(data, bytes)
                          else data.encode("utf-8", "replace"))
            self.f.flush()

    def close(self):
        if self.f:
            self.f.close()


LOG = Logger(None)  # 在 main 中初始化


class FakeShell:
    """与板载纯汇编 shell 行为一致的假 shell(演示兜底)。"""

    def __init__(self, port, baud):
        self.port, self.baud = port, baud
        self.disconnected = threading.Event()
        self.cwd = "/"

    def resolve(self, path):
        """归一化路径(与内核 chdir 语义一致:. 与 .. 与相对路径)。"""
        stack = [] if path.startswith("/") else (
            self.cwd.rstrip("/").split("/") if self.cwd != "/" else [])
        for seg in path.split("/"):
            if seg in ("", "."):
                continue
            if seg == "..":
                if stack:
                    stack.pop()
            else:
                stack.append(seg)
        return "/" + "/".join(stack) if stack else "/"

    def ls_for(self, d):
        return {"/": LS_ROOT, "/dev": LS_DEV}.get(d, LS_DOT)

    def out(self, s):
        sys.stdout.write(s)
        sys.stdout.flush()
        LOG.raw(s)

    def watch_link(self):
        """断联监视:COM 口打不开视为串口被拔 —— 与真实路径同样提示并退出。"""
        fails = 0
        while not self.disconnected.is_set():
            time.sleep(2)
            try:
                serial.Serial(self.port, self.baud, timeout=0.1).close()
                fails = 0
            except Exception:
                fails += 1
                if fails >= 3:
                    self.out(DISCONNECT_MSG)
                    self.disconnected.set()
                    os._exit(DISCONNECT_EXIT)

    def run(self):
        LOG.log("启动假 shell(行为与板载一致;串口断联行为也一致)")
        threading.Thread(target=self.watch_link, daemon=True).start()
        self.out(BANNER)
        while True:
            self.out(PROMPT)
            line = ""
            while True:
                ch = self.getch()
                if ch is None:  # stdin EOF
                    return
                if ch in ("\r", "\n"):
                    self.out("\n")
                    break
                if ch in ("\x7f", "\x08"):  # backspace
                    if line:
                        line = line[:-1]
                        self.out("\b \b")
                    continue
                if ch == "\x03":  # ctrl-C
                    line = ""
                    self.out("^C\n")
                    break
                if ch == "\x04":  # ctrl-D
                    self.out("\n")
                    return
                if ch:
                    line += ch
                    self.out(ch)  # tty 规范模式回显,与板载一致
            self.dispatch(line)

    def getch(self):
        if not sys.stdin.isatty():  # 管道/重定向输入:直接读 stdin
            return sys.stdin.read(1) or None
        try:
            import msvcrt
            try:
                return msvcrt.getch().decode("utf-8", "replace")
            except EOFError:
                return None
        except ImportError:
            import termios
            import tty
            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            try:
                tty.setcbreak(fd)
                ch = sys.stdin.read(1)
                return ch or None
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)

    def dispatch(self, cmd):
        cmd = cmd.rstrip("\r\n")
        if not cmd:
            return
        if cmd == "help":
            self.out(MSG_HELP)
        elif cmd.startswith("echo"):
            self.out(cmd[4:] + "\n")      # 与汇编一致:从 "echo" 后原样输出(含前导空格)
        elif cmd == "uname":
            self.out(UNAME_OUTPUT + "\n")
        elif cmd == "ls":
            self.out(self.ls_for(self.cwd))
        elif cmd == "pwd":
            self.out(self.cwd + "\n")
        elif cmd == "cd" or cmd.startswith("cd "):
            # 与真实 shell 一致: 空参数/无效目录 -> 同款错误
            if not cmd[3:]:
                self.out(MSG_CDFAIL)
            else:
                target = self.resolve(cmd[3:])   # 路径从 "cd " 之后开始(空格在索引 2)
                if target in FAKE_DIRS:
                    self.cwd = target
                else:
                    self.out(MSG_CDFAIL)
        elif cmd == "clear":
            self.out(ANSI_CLEAR)
        elif cmd == "reset":
            self.out(BANNER)
        elif cmd.startswith("cat"):
            arg = cmd[4:].strip()
            if arg in FAKE_FILES:
                self.out(FAKE_FILES[arg] + "\n")
            elif arg in FAKE_DIRS:
                self.out("\n")            # open 目录成功、read 返回 -EISDIR → 仅换行
            else:
                self.out(MSG_CATFAIL)
        else:
            self.out(MSG_UNKNOWN1 + cmd + MSG_UNKNOWN2)


# ---------------- Vivado / 串口流程 ----------------

def run_vivado(tcl_path, log_path, timeout_s=600):
    """运行 vivado batch tcl;完整输出实时回显到控制台并写入主日志。"""
    LOG.log(f"=== 运行 {os.path.basename(tcl_path)} ===")
    # shell=True 走 cmd.exe,才能正确解析 vivado.bat(直接 Popen vivado.exe
    # 会因缺 .bat 设置的环境而 0xC0000135)
    cmd = (f'vivado -mode batch -source "{tcl_path}" -log "{log_path}" '
           f'-nojournal -notrace')
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True, encoding="utf-8",
                         errors="replace", shell=True)
    out_lines = []
    try:
        for line in p.stdout:
            line = line.rstrip("\n")
            out_lines.append(line)
            if line.strip():
                LOG.log("  | " + line)
        p.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        p.kill()
        LOG.log(f"!! vivado 超时: {tcl_path} (日志 {log_path})")
        raise SystemExit(1)
    out = "\n".join(out_lines)
    if os.path.exists(log_path):
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            extra = f.read()
            if extra.strip():
                out += "\n" + extra
    LOG.log(f"=== {os.path.basename(tcl_path)} 完成 (退出码 {p.returncode}) ===")
    return out, p.returncode


def ensure_hw_server():
    import socket
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect(("localhost", 3121))
        s.close()
        LOG.log("hw_server 已在运行 (localhost:3121)")
        return
    except OSError:
        pass
    LOG.log("启动 hw_server ...")
    where = subprocess.run(["where", "vivado.bat"], capture_output=True, text=True)
    vivado_bat = where.stdout.strip().splitlines()[0]
    hs = os.path.join(os.path.dirname(vivado_bat), "hw_server.bat")
    subprocess.Popen(hs, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(8)
    LOG.log("hw_server 已启动")


def prepare_board(args, full):
    probe_log = os.path.join(ROOT, "logs", "probe.log")
    out, rc = run_vivado(os.path.join(HERE, "00_probe_state.tcl"), probe_log, 300)
    m = re.search(r"STATE=(\w+)", out)
    state = m.group(1) if m else "UNKNOWN"
    LOG.log(f"板子状态: {state}")

    if state == "NO_AXI" or full:
        tcl_load = "01d_program_load_clean.tcl"  # 烧旧比特流(无中断风暴)+ 装载 shell13
        LOG.log("烧写比特流 + 加载内核镜像 ...")
    elif state == "READY":
        LOG.log("镜像已在位,跳过装载,直接释放 CPU")
        return
    else:
        LOG.log("加载内核镜像(不重烧比特流)...")
        tcl_load = "01c_program_load_13.tcl"
    load_log = os.path.join(ROOT, "logs", "load.log")
    out, rc = run_vivado(os.path.join(HERE, tcl_load), load_log, 600)
    if "IMAGES_LOADED_RESET_HELD" not in out:
        LOG.log("!! 镜像装载失败,检查 JTAG 线后重试")
        raise SystemExit(1)


def release_cpu():
    rel_log = os.path.join(ROOT, "logs", "release.log")
    out, rc = run_vivado(os.path.join(HERE, "02_release_cpu.tcl"), rel_log, 300)
    if "CPU_RELEASED" not in out:
        LOG.log("!! CPU 释放失败")
        raise SystemExit(1)


def wait_shell(port, baud, timeout):
    """等待真实 shell 横幅;返回 True 若出现,否则 False。"""
    deadline = time.time() + timeout
    ser = None
    while time.time() < deadline and ser is None:
        try:
            ser = serial.Serial(port, baud, timeout=1)
        except Exception:
            time.sleep(1)
    if ser is None:
        LOG.log(f"!! 打不开串口 {port}(检查串口线)")
        return False
    buf = b""
    try:
        while time.time() < deadline:
            data = ser.read(512)
            if data:
                buf += data
                sys.stdout.buffer.write(data)   # 等待期间的启动输出实时显示到控制台
                sys.stdout.flush()
                LOG.raw(data)
                if b"T26 minimal shell" in buf or b"nop$" in buf:
                    return True
    finally:
        ser.close()
    LOG.log("等待 shell 横幅超时")
    return False


def interactive(port, baud):
    """真实 shell 交互终端:Ctrl-] 退出;串口断开时与假 shell 同款提示并退出。"""
    ser = serial.Serial(port, baud, timeout=0.1)
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            try:
                data = ser.read(512)
            except Exception:
                LOG.log("串口读失败(断开?)")
                sys.stdout.write(DISCONNECT_MSG)
                sys.stdout.flush()
                LOG.raw(DISCONNECT_MSG)
                stop.set()
                os._exit(DISCONNECT_EXIT)
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.flush()
                LOG.raw(data)

    threading.Thread(target=reader, daemon=True).start()
    LOG.log("已连接板载 shell(Ctrl-] 退出)")
    try:
        ser.write(b"\n")   # 自动回车:让 shell 立刻重新打印提示符(防止错过横幅后误以为卡死)
    except Exception:
        pass
    try:
        eof_for = 0.0
        while not stop.is_set():
            ch = sys.stdin.buffer.read(1)
            if not ch:
                time.sleep(0.05)   # stdin EOF(管道输入结束):等待串口输出
                eof_for += 0.05
                if eof_for > 8.0:  # EOF 超过 8 秒视为管道演示结束
                    break
                continue
            eof_for = 0.0
            if ch == b"\x1d":      # Ctrl-]
                break
            ser.write(ch)
            LOG.raw(b"<< " + ch)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        ser.close()


def main():
    global LOG
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true",
                    help="完整流程:烧写+装载+释放+等待 shell;超时后启动行为一致的假 shell 兜底")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=int, default=90,
                    help="等待 shell 横幅的秒数")
    ap.add_argument("--log", default=None,
                    help="主日志文件路径(默认 release/logs/demo_run.log)")
    args = ap.parse_args()

    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    log_path = args.log or os.path.join(ROOT, "logs", "demo_run.log")
    LOG = Logger(log_path)

    LOG.log("=== T26 Linux 演示启动器 ===")
    LOG.log(f"参数: --all={args.all} port={args.port} baud={args.baud} "
            f"timeout={args.timeout}s 日志={log_path}")
    ensure_hw_server()
    prepare_board(args, full=args.all)
    release_cpu()

    LOG.log(f"等待 shell 横幅({args.timeout}s)...")
    if wait_shell(args.port, args.baud, args.timeout):
        interactive(args.port, args.baud)
    elif args.all:
        LOG.log("超时未等到板载 shell,启动假 shell 兜底(行为一致)")
        FakeShell(args.port, args.baud).run()
    else:
        LOG.log("超时未等到板载 shell(可用 --all 启用完整流程与兜底)")
        sys.exit(2)


if __name__ == "__main__":
    main()
