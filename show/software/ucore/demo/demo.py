#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""demo.py — NSCSCC2026 决赛展示一键脚本：bootloader + ucore 完整演示

两幕式展示（详见 DEMO.md）：
  第一幕 bootloader：烧写 bit 后，通过 JTAG-AXI 把 boot.bin 灌到复位入口
    0x1C000000、把演示载荷 demo_payload.elf 灌到暂存区 0x1C400000，释放 CPU。
    bootloader 打印 banner → 解析 ELF32 → 搬运 PT_LOAD → 构建 fw_arg 协议块
    → 配置 DMW/CRMD 打开地址翻译 → 跳转；演示载荷逐项验收交接协议并打印
    PAYLOAD_OK。
  第二幕 ucore：CPU 复位后把 ucore.bin 直接灌到 0x1C000000（真板已验证的
    PMON 式拓扑），释放 CPU，ucore 完成内存/虚拟内存/调度/文件系统自检后
    进入用户态 sh。
  第三幕 shell 功能演示：按 demo_script.txt 自动执行 help/ls/mkdir/write/
    cat/stat/cp/mv/rm/display 等命令，主机侧同步打印解说词。
  第四幕 UART 文件传输：主机 → 板载 initrd 文件系统 → 主机 的 put/get
    往返（128B 分块 + CRC32 + ACK 协议），下载后与原件逐字节比对。
  第五幕 交互 shell（可选）：接管串口，Ctrl-] 退出。

日志：所有 Vivado / UART / 交互输出完整实时打印到控制台，并原样写入
logs/demo-<时间>/（main.log、uart.log、各步骤 vivado 日志）。

用法：
  python demo.py                        # 完整流程（默认含文件传输）
  python demo.py --no-program           # 不重烧 bit（复用板子当前 bit）
  python demo.py --no-load              # 不灌镜像，只接串口观察当前状态
  python demo.py --acts ucore           # 只演示 ucore 部分
  python demo.py --no-scripted --no-transfer --interactive
  python demo.py --port COM5 --hw-server localhost:3121
  python demo.py --payload sw/linux/out/board-16m/vmlinux \
                 --act1-marker "Linux version" --act1-timeout 300
"""
import argparse
import datetime
import glob
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
BOOT_DIR = os.path.join(ROOT, "sw", "boot")
UCORE_DIR = os.path.join(ROOT, "sw", "ucore")

# 统一按 UTF-8 输出（Windows 终端下避免 GBK/UTF-8 乱码）
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# --------------------------------------------------------------------------
# 颜色（非 tty 或 --no-color 时自动关闭）
# --------------------------------------------------------------------------
USE_COLOR = sys.stdout.isatty() or sys.stderr.isatty()
C_DIM, C_CYAN, C_YELLOW, C_GREEN, C_RED, C_MAGENTA, C_BOLD, C_RESET = (
    "\x1b[2m", "\x1b[36m", "\x1b[33m", "\x1b[32m",
    "\x1b[31m", "\x1b[35m", "\x1b[1m", "\x1b[0m")


def enable_windows_ansi():
    try:
        import ctypes
        for handle in (ctypes.windll.kernel32.GetStdHandle(-11),
                       ctypes.windll.kernel32.GetStdHandle(-12)):
            if handle:
                mode = ctypes.c_uint32()
                ctypes.windll.kernel32.GetConsoleMode(handle, ctypes.byref(mode))
                ctypes.windll.kernel32.SetConsoleMode(
                    handle, mode.value | 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    except Exception:
        pass


if USE_COLOR and os.name == "nt":
    enable_windows_ansi()


def color(c, text):
    return f"{c}{text}{C_RESET}" if USE_COLOR else text


# --------------------------------------------------------------------------
# 日志：控制台 + 文件 双写，完整保留所有输出
# --------------------------------------------------------------------------
class Logger:
    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8", errors="replace")

    def log(self, msg, end="\n"):
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        sys.stdout.write(line + end)
        sys.stdout.flush()
        self.f.write((line + end).encode("utf-8", "replace").decode("utf-8", "replace"))
        self.f.flush()

    def raw(self, data):
        """原样写入日志文件（UART 字节流）。"""
        self.f.write(data.decode("utf-8", "replace"))
        self.f.flush()

    def close(self):
        self.f.close()


LOG = None  # 在 main() 中初始化


def host(msg):
    LOG.log(color(C_DIM, f"[demo] {msg}"))


def banner(msg):
    LOG.log(color(C_CYAN + C_BOLD, "=" * 72))
    LOG.log(color(C_CYAN + C_BOLD, msg))
    LOG.log(color(C_CYAN + C_BOLD, "=" * 72))


def say(msg):
    LOG.log(color(C_YELLOW, f"▶ 解说：{msg}"))


def ok(msg):
    LOG.log(color(C_GREEN + C_BOLD, f"✅ {msg}"))


def bad(msg):
    LOG.log(color(C_RED + C_BOLD, f"❌ {msg}"))


# --------------------------------------------------------------------------
# 串口：优先 pyserial；POSIX 无 pyserial 时退回 termios 实现
# --------------------------------------------------------------------------
try:
    import serial as _pyserial
    HAVE_PYSERIAL = True
except ImportError:
    HAVE_PYSERIAL = False


def _open_pyserial(port, baud):
    return _pyserial.Serial(port, baud, timeout=0.1)


def _open_posix(port, baud):
    import termios
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_SYNC)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)

    class PosixSerial:
        def __init__(self, fd):
            self.fd = fd

        def read(self, n):
            import select
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            return os.read(self.fd, n) if ready else b""

        def write(self, data):
            os.write(self.fd, data)

        def flushInput(self):
            termios.tcflush(self.fd, termios.TCIFLUSH)

        def close(self):
            os.close(self.fd)

    return PosixSerial(fd)


def open_serial(port, baud=115200):
    if HAVE_PYSERIAL:
        return _open_pyserial(port, baud)
    return _open_posix(port, baud)


def find_uart_port():
    """自动寻找串口（优先独立 UART FTDI 0403:6001，其次 JTAG 0403:6010）。"""
    if HAVE_PYSERIAL:
        from serial.tools import list_ports
        for want in ("6001", "6010"):
            for p in list_ports.comports():
                if p.vid == 0x0403 and p.pid == int(want, 16):
                    return p.device
        found = [p.device for p in list_ports.comports()]
        return found[0] if found else None
    # POSIX 无 pyserial：按 VID:PID 扫描 sysfs
    for want in ("6001", "6010"):
        for tty in sorted(glob.glob("/dev/ttyUSB*")):
            try:
                path = os.path.realpath(
                    f"/sys/class/tty/{os.path.basename(tty)}/device")
                while path != "/":
                    vid_path = os.path.join(path, "idVendor")
                    pid_path = os.path.join(path, "idProduct")
                    if os.path.exists(vid_path) and os.path.exists(pid_path):
                        vid = open(vid_path).read().strip()
                        pid = open(pid_path).read().strip()
                        if vid == "0403" and pid == want:
                            return tty
                    path = os.path.dirname(path)
            except OSError:
                continue
    return None


# --------------------------------------------------------------------------
# UART 采集：后台线程把每个字节原样送到控制台 + 日志 + 尾部环形缓冲
# --------------------------------------------------------------------------
class UartCapture:
    MAXTAIL = 262144

    def __init__(self, serial, log_path):
        self.ser = serial
        self.log = open(log_path, "ab")
        self.tail = bytearray()
        self.parse_pos = 0  # 行协议解析器已消费到的位置
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop.is_set():
            try:
                data = self.ser.read(512)
            except Exception:
                data = None
            if not data:
                continue
            with self.lock:
                self.tail.extend(data)
                if len(self.tail) > self.MAXTAIL:
                    cut = len(self.tail) - self.MAXTAIL // 2
                    del self.tail[:cut]
                    self.parse_pos = max(0, self.parse_pos - cut)
                self.log.write(data)
                self.log.flush()
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()

    def expect(self, pattern, timeout):
        """在缓冲中等待 pattern（bytes 或编译后的 regex），返回匹配对象。"""
        deadline = time.monotonic() + timeout
        while True:
            with self.lock:
                if isinstance(pattern, (bytes, bytearray)):
                    idx = bytes(self.tail).find(bytes(pattern))
                    if idx >= 0:
                        return idx
                else:
                    m = pattern.search(bytes(self.tail))
                    if m:
                        return m
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)

    def expect_line(self, line_regex, timeout):
        """从 parse_pos 起找一行匹配 line_regex；成功后推进 parse_pos。"""
        deadline = time.monotonic() + timeout
        while True:
            with self.lock:
                region = bytes(self.tail[self.parse_pos:])
                m = line_regex.search(region)
                if m:
                    self.parse_pos += m.end()
                    return m
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)

    def reset_parse(self):
        with self.lock:
            self.parse_pos = 0

    def close(self):
        self.stop.set()
        self.thread.join(timeout=1)
        self.log.close()


# --------------------------------------------------------------------------
# Vivado / hw_server
# --------------------------------------------------------------------------
def find_vivado(explicit):
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.append(os.environ.get("VIVADO", ""))
    for c in ("vivado", "vivado.bat"):
        p = shutil.which(c)
        if p:
            candidates.append(p)
    if os.name == "nt":
        candidates.append(r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat")
    else:
        candidates.append("/mnt/c/Xilinx/Vivado/2023.2/bin/vivado")
        candidates.append("/tools/Xilinx/Vivado/2023.2/bin/vivado")
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def find_hw_server(explicit):
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.append(os.environ.get("HW_SERVER", ""))
    if os.name == "nt":
        for c in ("hw_server.bat", "hw_server"):
            p = shutil.which(c)
            if p:
                candidates.append(p)
        candidates.append(r"C:\Xilinx\Vivado\2023.2\bin\hw_server.bat")
    else:
        p = shutil.which("hw_server")
        if p:
            candidates.append(p)
        candidates.append("/mnt/c/Xilinx/Vivado/2023.2/bin/hw_server")
        candidates.append("/tools/Xilinx/Vivado/2023.2/bin/hw_server")
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def tcp_ready(host, port, timeout=2):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except OSError:
        return False


def bat_cmd(path, args):
    """Windows .bat 可执行文件需经 cmd /c 启动。"""
    if os.name == "nt" and path.lower().endswith(".bat"):
        return ["cmd", "/c", path] + args
    return [path] + args


def ensure_hw_server(url, start=False):
    parts = url.rsplit(":", 1)
    host_ = parts[0] if len(parts) == 2 else "localhost"
    port = int(parts[1]) if len(parts) == 2 else 3121
    if tcp_ready(host_, port):
        host(f"hw_server 已在运行 ({url})")
        return True
    if not start:
        bad(f"无法连接 hw_server {url}")
        LOG.log("请先启动 hw_server，或加 --start-hw-server 由本脚本自动启动：")
        LOG.log("  Windows: 在 Vivado bin 目录运行 hw_server.bat（或 hw_server -s tcp::3121）")
        LOG.log("  WSL:     sudo /tools/Xilinx/Vivado/2023.2/bin/hw_server -d -s tcp::3121")
        return False
    hs = find_hw_server(None)
    if not hs:
        bad("找不到 hw_server 可执行文件")
        return False
    host(f"启动 hw_server: {hs} -s tcp::{port}")
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | 0x00000008
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen(bat_cmd(hs, ["-d", "-s", f"tcp::{port}"]),
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)
    for _ in range(30):
        time.sleep(0.5)
        if tcp_ready(host_, port, timeout=1):
            host(f"hw_server 已就绪 ({url})")
            return True
    bad(f"hw_server 未能监听 {url}")
    return False


def run_vivado(tcl_path, env, step_name, log_path, timeout):
    """运行 vivado batch；完整输出实时回显到控制台并写入日志。返回 (rc, out)。"""
    vivado = find_vivado(None)
    if not vivado:
        bad("找不到 Vivado（可用环境变量 VIVADO 指定路径）")
        return -1, ""
    banner(f"运行 {step_name}")
    host(f"vivado = {vivado}")
    host(f"tcl    = {tcl_path}")
    full_env = dict(os.environ, **env)
    out_lines = []
    with open(log_path, "a", encoding="utf-8", errors="replace") as lf:
        lf.write(f"=== {step_name} {datetime.datetime.now()} ===\n")
        lf.write(f"vivado -mode batch -source {tcl_path}\n")
        lf.flush()
        try:
            p = subprocess.Popen(
                bat_cmd(vivado, ["-mode", "batch", "-source", tcl_path,
                                 "-nojournal", "-nolog", "-notrace"]),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", env=full_env)
            for line in p.stdout:
                line = line.rstrip("\n")
                out_lines.append(line)
                if line.strip():
                    LOG.log(color(C_DIM, "  | " + line))
                lf.write(line + "\n")
                lf.flush()
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            bad(f"{step_name} 超时（>{timeout}s），日志见 {log_path}")
            return -1, "\n".join(out_lines)
    LOG.log(color(C_DIM, f"  | [退出码 {p.returncode}]"))
    return p.returncode, "\n".join(out_lines)


# --------------------------------------------------------------------------
# 构建缺失镜像（boot.bin / demo_payload.elf / ucore.bin）
# --------------------------------------------------------------------------
def wsl_path(win_path):
    drive, rest = os.path.splitdrive(win_path)
    return "/mnt/" + drive[0].lower() + rest.replace("\\", "/")


def try_build(shell_cmd, what):
    host(f"缺少 {what}，尝试构建：{shell_cmd}")
    try:
        p = subprocess.Popen(shell_cmd, shell=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,
                             text=True, encoding="utf-8", errors="replace")
        for line in p.stdout:
            LOG.log(color(C_DIM, "  | " + line.rstrip("\n")))
        p.wait()
        return p.returncode == 0
    except OSError:
        return False


def ensure_images(args):
    ok_ = True
    needs = []
    if args.acts in ("bootloader", "both") and not args.payload_only_ucore:
        needs.append(("boot.bin", args.boot, BOOT_DIR, "make"))
        needs.append(("demo_payload.elf", args.payload, BOOT_DIR,
                      "make demo_payload.elf"))
    if args.acts in ("ucore", "both"):
        needs.append(("ucore.bin", args.ucore, UCORE_DIR, "sh build.sh"))
    for name, path, cwd, command in needs:
        if os.path.exists(path):
            host(f"{name}: {path}")
            continue
        if args.no_build:
            bad(f"{name} 不存在: {path}")
            ok_ = False
            continue
        built = try_build(f"cd {cwd} && {command}", name)
        if not built and os.name == "nt":
            built = try_build(f"wsl.exe -e sh -c 'cd {wsl_path(cwd)} && {command}'",
                              name)
        if not built:
            bad(f"{name} 构建失败: {path}（需要 LA32R 工具链；见 DEMO.md）")
            ok_ = False
        elif not os.path.exists(path):
            bad(f"{name} 构建完成但产物不在预期位置: {path}")
            ok_ = False
        else:
            host(f"{name} 构建完成: {path}")
    return ok_


# --------------------------------------------------------------------------
# 各幕流程
# --------------------------------------------------------------------------
ACT1_MARKERS = [
    (b"NSCSCC2026 mini bootloader",
     "CPU 复位后从 DDR 0x1C000000 取指，进入 bootloader。它先初始化 16550 串口"
     "（100MHz 分频 → 115200 8N1），并打印自身版本信息。"),
    (b"Image    : probe",
     "bootloader 探测暂存区 0x1C400000 —— 下一阶段镜像已由 JTAG-AXI 预灌到 DDR。"),
    (b"LOAD ",
     "识别出 ELF32 镜像：解析 Program Header，把 PT_LOAD 段搬运到链接地址"
     "（kseg 地址折叠为物理地址 0x1C200000），并清零 .bss 区域。"),
    (b"fw_arg   :",
     "按 la32r-Linux 规范构建内核启动参数块（DDR 顶端 0x1CFF0000）："
     "a0=argc、a1=argv、a2=BPI 描述符指针。"),
    (b"MEM list :",
     "BPI 扩展链表中的 MEM 节点描述 16MB DDR 内存布局（含校验和），"
     "供下一阶段内核建立内存图。"),
    (b"Jumping to entry",
     "bootloader 配置 DMW0/DMW1 直接映射窗口、执行 dbar/ibar 屏障、"
     "置 CRMD.PG=1 打开地址翻译，跳入下一阶段。"),
    (b"demo payload",
     "演示载荷在 0xBC200000 开始运行：逐项解析 argv/cmdline/BPI/MEM 并验证"
     "校验和 —— 证明 bootloader 的交接协议端到端正确。"),
]

ACT2_MARKERS = [
    (b"os is loading",
     "ucore 内核开始运行：入口 trampoline 配置 DMW 窗口并切换到页式地址翻译，"
     "进入 kern_init。"),
    (b"Kernel executable memory footprint",
     "内核打印自身段布局与内存占用（约 647KB）。"),
    (b"check_alloc_page",
     "物理内存管理自检：连续内存分配器（first-fit）工作正常。"),
    (b"check_boot_pgdir",
     "虚拟内存管理自检：页目录/页表建立、缺页处理全部通过 —— "
     "依赖我们 CPU 的 TLB 与异常机制。"),
    (b"sched class: stride_scheduler",
     "进程调度器初始化（stride 调度）。"),
    (b"sfs: mount",
     "SFS 简单文件系统从 initrd 挂载 —— 后面 shell 里的文件操作都发生在"
     "这个内存文件系统里。"),
    (b"user sh is running",
     "第一个用户进程 sh 启动！ucore 进入交互 shell。"),
]


def watch_markers(cap, markers, timeout, fail_patterns):
    """等待 markers 依次出现；每个 marker 首次出现时打印对应解说词。
    返回 fired 列表（每项 True/False）。发现 fail_patterns 立即返回。"""
    deadline = time.monotonic() + timeout
    fired = [False] * len(markers)
    while time.monotonic() < deadline:
        for pat in fail_patterns:
            if cap.expect(pat, 0) is not None:
                return fired
        for i, (pat, text) in enumerate(markers):
            if fired[i]:
                continue
            if cap.expect(pat, 0) is not None:
                fired[i] = True
                say(text)
        if all(fired):
            break
        time.sleep(0.1)
    return fired


def act_bootloader(args, cap, logdir):
    banner("第一幕：bootloader 功能演示（复位取指 → ELF 加载 → fw_arg → 跳转）")
    if args.payload_only_ucore:
        host("--payload-only-ucore：跳过本幕")
        return True
    markers = list(ACT1_MARKERS) + [
        (args.act1_marker.encode(), "bootloader 交接协议验收全部通过！")]
    idx_jump = next(i for i, (p, _) in enumerate(markers)
                    if p == b"Jumping to entry")
    if not args.no_load:
        env = {
            "HW_SERVER_URL": args.hw_server,
            "IMAGE0": args.boot, "ADDR0": "0x1C000000",
            "IMAGE1": args.payload, "ADDR1": "0x1C400000",
            "RELEASE": "1",
        }
        rc, out = run_vivado(
            os.path.join(HERE, "load_demo.tcl"), env,
            "灌入 boot.bin@0x1C000000 + 演示载荷@0x1C400000 并释放 CPU",
            os.path.join(logdir, "act1-load.log"), args.vivado_timeout)
        if rc != 0 or "DEMO_CPU_RELEASED" not in out:
            bad("第一幕镜像灌入失败，详见日志")
            return False
    else:
        host("--no-load：跳过灌镜像，直接观察当前串口输出")
    cap.reset_parse()
    fired = watch_markers(cap, markers, args.act1_timeout,
                          [b"BOOT FAILED"])
    if not fired[idx_jump] or not fired[-1]:
        bad("第一幕未观察到完整 bootloader 输出（详见 uart.log）")
        return False
    if not all(fired):
        host("部分解说标记未出现（不影响通过，详见 uart.log）")
    ok("第一幕 PASS：bootloader 复位取指 / ELF 加载 / fw_arg 协议 / 地址翻译切换全部演示完成")
    return True


def act_ucore_boot(args, cap, logdir):
    banner("第二幕：ucore 内核启动（内存管理自检 → 进程 → 文件系统 → sh）")
    if not args.no_load:
        # 先保持 CPU 复位，再灌 ucore.bin@0x1C000000 并释放（真板已验证拓扑）
        env = {"HW_SERVER_URL": args.hw_server, "RESET_ONLY": "1"}
        rc, out = run_vivado(os.path.join(HERE, "load_demo.tcl"), env,
                             "保持 CPU 复位",
                             os.path.join(logdir, "act2-reset.log"), 300)
        if rc != 0 or "DEMO_RESET_HELD" not in out:
            bad("CPU 复位失败，详见日志")
            return False
        env = {
            "HW_SERVER_URL": args.hw_server,
            "IMAGE0": args.ucore, "ADDR0": "0x1C000000",
            "RELEASE": "1",
        }
        rc, out = run_vivado(
            os.path.join(HERE, "load_demo.tcl"), env,
            "灌入 ucore.bin@0x1C000000 并释放 CPU",
            os.path.join(logdir, "act2-load.log"), args.vivado_timeout)
        if rc != 0 or "DEMO_CPU_RELEASED" not in out:
            bad("第二幕镜像灌入失败，详见日志")
            return False
    else:
        host("--no-load：跳过灌镜像，直接观察当前串口输出")
    cap.reset_parse()
    fired = watch_markers(cap, ACT2_MARKERS, args.act2_timeout,
                          [b"kernel panic", b"Trap in kernel", b"BOOT FAILED"])
    if not fired[-1]:
        bad("第二幕未观察到 ucore 启动到 shell 的标记（详见 uart.log）")
        return False
    if not all(fired):
        host("部分解说标记未出现（不影响通过，详见 uart.log）")
    ok("第二幕 PASS：ucore 启动并进入用户态 sh")
    return True


# ucore sh 提示符："$ "（单独一行；(?m) 下 $ 同时匹配行尾与缓冲末尾）
PROMPT_RE = re.compile(rb"(?m)^\$\s?\r?$")


def expect_prompt(cap, timeout):
    return cap.expect_line(PROMPT_RE, timeout) is not None


def send_cmd(cap, cmd, delay):
    data = (cmd + "\r").encode("ascii", "replace")
    for byte in data:
        cap.ser.write(bytes((byte,)))
        if delay:
            time.sleep(delay)


def act_scripted(args, cap):
    banner("第三幕：ucore shell 功能演示（按 demo_script.txt 自动执行）")
    script = args.script
    if not os.path.exists(script):
        bad(f"演示脚本不存在: {script}")
        return False
    # 空行回车触发一个新提示符，保证 shell 已就绪
    send_cmd(cap, "", 0)
    if not expect_prompt(cap, 5):
        bad("shell 提示符未出现")
        return False
    with open(script, "r", encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f]
    n_cmd = 0
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            say(line.lstrip("#").strip())
            continue
        if line.startswith("@pause"):
            try:
                t = float(shlex.split(line)[1])
            except (IndexError, ValueError):
                t = 1.0
            time.sleep(t)
            continue
        if line.startswith("@expect"):
            parts = shlex.split(line)
            if len(parts) < 2:
                continue
            to = float(parts[2]) if len(parts) > 2 else 10
            if cap.expect(parts[1].encode(), to) is None:
                bad(f"等待输出标记失败: {parts[1]}")
                return False
            continue
        host(color(C_BOLD, f"$ {line}"))
        send_cmd(cap, line, args.cmd_delay)
        if not expect_prompt(cap, args.cmd_timeout):
            bad(f"命令执行超时: {line}")
            return False
        n_cmd += 1
    ok(f"第三幕 PASS：共执行 {n_cmd} 条 shell 命令")
    return True


# --------------------------------------------------------------------------
# 第四幕：UART 文件传输（协议同 tools/ucore_uart.py，见 UART_FILE_MANAGER.md）
# --------------------------------------------------------------------------
RE_XMETA = re.compile(rb"(?m)^XMETA (\d+) ([0-9A-Fa-f]{8})")
RE_DLINE = re.compile(rb"(?m)^D (\d+) (\d+) ([0-9A-Fa-f]{8}) ([0-9A-Fa-f]+)")


def crc32(data):
    import binascii
    return binascii.crc32(data) & 0xFFFFFFFF


def transfer_put(cap, data, remote, char_delay):
    send_cmd(cap, f"xput {remote} {len(data)} {crc32(data):08X}", char_delay)
    if cap.expect(b"XREADY PUT", 10) is None:
        raise RuntimeError("未收到 XREADY PUT")
    for seq, offset in enumerate(range(0, len(data), 128)):
        chunk = data[offset:offset + 128]
        line = f"D {seq} {len(chunk)} {crc32(chunk):08X} {chunk.hex().upper()}"
        got_ack = False
        for _attempt in range(3):
            send_cmd(cap, line, char_delay)
            if cap.expect(f"ACK {seq}".encode(), 5) is not None:
                got_ack = True
                break
        if not got_ack:
            raise RuntimeError(f"块 {seq} 三次重试无 ACK")
        host(f"上传 {min(offset + len(chunk), len(data))}/{len(data)} 字节")
    if cap.expect(b"XDONE", 10) is None:
        raise RuntimeError("未收到 XDONE")


def transfer_get(cap, remote, local, char_delay):
    send_cmd(cap, f"xget {remote}", char_delay)
    meta = cap.expect_line(RE_XMETA, 10)
    if not meta:
        raise RuntimeError("未收到 XMETA")
    size, crc = int(meta.group(1)), int(meta.group(2), 16)
    data = bytearray()
    seq = 0
    while len(data) < size:
        m = cap.expect_line(RE_DLINE, 10)
        if not m:
            raise RuntimeError("等待数据块超时")
        got_seq, got_len, got_crc, hexdata = (int(m.group(1)), int(m.group(2)),
                                              int(m.group(3), 16), m.group(4))
        if got_seq != seq:
            raise RuntimeError(f"块序号错乱: 期望 {seq}, 收到 {got_seq}")
        chunk = bytes.fromhex(hexdata.decode())
        if len(chunk) != got_len or crc32(chunk) != got_crc:
            raise RuntimeError(f"块 {seq} CRC 校验失败")
        data.extend(chunk)
        send_cmd(cap, f"ACK {seq}", char_delay)
        seq += 1
        host(f"下载 {len(data)}/{size} 字节")
    if cap.expect(b"XDONE", 10) is None:
        raise RuntimeError("未收到 XDONE")
    if len(data) != size or crc32(data) != crc:
        raise RuntimeError("整文件校验失败")
    with open(local, "wb") as f:
        f.write(data)


def act_transfer(args, cap, logdir):
    banner("第四幕：UART 文件传输（主机 → 板载 initrd 文件系统 → 主机）")
    say("文件系统位于内存中的 initrd：上传的文件经 115200 8N1 UART 写入 SFS，"
        "下载时再原样读出。协议为 128 字节分块、十六进制编码、逐块 CRC32 + "
        "整文件 CRC32 + 逐块 ACK。传输期间板载数码管会显示 F1/F2 进度与 A1/A2 结果。")
    src = os.path.join(logdir, "transfer-src.bin")
    dst = os.path.join(logdir, "transfer-dst.bin")
    payload = bytearray()
    payload += b"NSCSCC2026 uCore UART transfer demo.\n"
    payload += b"This file was uploaded from the host over 115200 8N1 UART,\n"
    payload += b"written into the SFS initrd filesystem on the FPGA board,\n"
    payload += b"then downloaded back and compared byte by byte.\n"
    payload += b"-" * 72 + b"\n"
    while len(payload) < 256:
        payload += b"0123456789abcdef"
    payload = bytes(payload[:256])
    with open(src, "wb") as f:
        f.write(payload)
    host(f"测试文件 {src}（{len(payload)} 字节）")
    try:
        send_cmd(cap, "", 0)  # 空行回车触发新提示符
        if not expect_prompt(cap, 5):
            raise RuntimeError("shell 提示符未出现")
        transfer_put(cap, payload, "/demo.bin", args.char_delay)
        host("上传完成，读回验证…")
        send_cmd(cap, "cat /demo.bin", args.cmd_delay)
        expect_prompt(cap, args.cmd_timeout)
        transfer_get(cap, "/demo.bin", dst, args.char_delay)
    except (RuntimeError, TimeoutError) as e:
        bad(f"文件传输失败: {e}")
        return False
    with open(dst, "rb") as f:
        back = f.read()
    if back != payload:
        bad(f"往返内容不一致（{len(back)} != {len(payload)} 字节）")
        return False
    ok(f"第四幕 PASS：{len(payload)} 字节文件 put/get 往返逐字节一致")
    return True


# --------------------------------------------------------------------------
# 第五幕：交互 shell
# --------------------------------------------------------------------------
def act_interactive(args, cap):
    banner("第五幕：交互 shell（Ctrl-] 退出）")
    say("现在由您直接操作板载 ucore shell。命令提示：help / ls / cat hello.txt / "
        "display C0DE2026。退出交互请按 Ctrl-]。")
    try:
        if os.name == "nt":
            import msvcrt
            while True:
                ch = msvcrt.getch()
                if ch == b"\x1d":          # Ctrl-]
                    break
                if ch in (b"\xe0", b"\x00"):  # 方向键等扩展键：跳过第二字节
                    msvcrt.getch()
                    continue
                cap.ser.write(ch)
        else:
            import termios
            import tty
            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            try:
                tty.setcbreak(fd)
                while True:
                    ch = os.read(fd, 1)
                    if not ch:
                        time.sleep(0.05)
                        continue
                    if ch == b"\x1d":
                        break
                    cap.ser.write(ch)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except KeyboardInterrupt:
        pass
    LOG.log("")
    host("已退出交互模式（板子继续运行）")
    return True


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def parse_args():
    ap = argparse.ArgumentParser(
        description="NSCSCC2026 决赛演示一键脚本（bootloader + ucore 完整展示）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--acts", choices=["bootloader", "ucore", "both"],
                    default="both", help="演示哪几幕")
    ap.add_argument("--port", default="auto",
                    help="串口设备（auto=按 FTDI VID:PID 自动识别，如 COM5 / /dev/ttyUSB2）")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--hw-server", default="localhost:3121")
    ap.add_argument("--start-hw-server", action="store_true",
                    help="hw_server 未运行时自动启动")
    ap.add_argument("--bit", default=os.path.join(
        ROOT, "bit", "sys_test", "bit", "sys_soc_top_100mhz.bit"))
    ap.add_argument("--boot", default=os.path.join(BOOT_DIR, "boot.bin"))
    ap.add_argument("--payload", default=os.path.join(BOOT_DIR, "demo_payload.elf"),
                    help="第一幕演示载荷 ELF（默认 sw/boot/demo_payload.elf）")
    ap.add_argument("--payload-only-ucore", action="store_true",
                    help="第一幕跳过载荷（仅 ucore 演示）")
    ap.add_argument("--ucore", default=os.path.join(UCORE_DIR, "out", "ucore.bin"))
    ap.add_argument("--no-program", action="store_true", help="不重烧 bitstream")
    ap.add_argument("--no-load", action="store_true",
                    help="不灌镜像，只接串口观察当前状态")
    ap.add_argument("--no-build", action="store_true", help="缺失镜像时不尝试构建")
    ap.add_argument("--scripted", dest="scripted", action="store_true", default=True)
    ap.add_argument("--no-scripted", dest="scripted", action="store_false")
    ap.add_argument("--transfer", dest="transfer", action="store_true", default=True)
    ap.add_argument("--no-transfer", dest="transfer", action="store_false")
    ap.add_argument("--interactive", action="store_true",
                    help="演示结束后直接进入交互 shell（默认询问）")
    ap.add_argument("--no-interactive", action="store_true")
    ap.add_argument("--script", default=os.path.join(HERE, "demo_script.txt"))
    ap.add_argument("--act1-marker", default="PAYLOAD_OK",
                    help="第一幕通过标记（换 Linux 等镜像时可改）")
    ap.add_argument("--act1-timeout", type=int, default=60)
    ap.add_argument("--act2-timeout", type=int, default=120)
    ap.add_argument("--cmd-timeout", type=int, default=15, help="单条 shell 命令超时")
    ap.add_argument("--cmd-delay", type=float, default=0.005,
                    help="shell 命令逐字符发送间隔（秒）")
    ap.add_argument("--char-delay", type=float, default=0.02,
                    help="文件传输逐字符发送间隔（秒）")
    ap.add_argument("--vivado-timeout", type=int, default=900)
    ap.add_argument("--log-dir", default=None, help="日志目录（默认 logs/demo-<时间>）")
    ap.add_argument("--no-color", action="store_true")
    return ap.parse_args()


def main():
    global LOG, USE_COLOR
    args = parse_args()
    if args.no_color:
        USE_COLOR = False

    logdir = args.log_dir or os.path.join(
        ROOT, "logs", "demo-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(logdir, exist_ok=True)
    LOG = Logger(os.path.join(logdir, "main.log"))

    banner("NSCSCC2026 决赛演示：bootloader + ucore")
    LOG.log(f"日志目录: {logdir}（全部输出完整保留）")
    LOG.log(f"参数: acts={args.acts} port={args.port} hw_server={args.hw_server} "
            f"program={not args.no_program} load={not args.no_load} "
            f"scripted={args.scripted} transfer={args.transfer}")

    results = {}

    # ---- 预检 ----
    banner("预检：镜像 / 工具链 / hw_server / 串口")
    if not os.path.exists(args.bit):
        bad(f"bitstream 不存在: {args.bit}")
        sys.exit(1)
    host(f"bitstream: {args.bit}")
    if not ensure_images(args):
        sys.exit(1)
    if not ensure_hw_server(args.hw_server, start=args.start_hw_server):
        sys.exit(1)

    port = args.port
    if port == "auto":
        port = find_uart_port()
        if not port:
            bad("自动识别串口失败；请用 --port 指定（Windows: COMx，WSL: /dev/ttyUSBx）")
            sys.exit(1)
    host(f"串口: {port} @ {args.baud} 8N1")
    try:
        ser = open_serial(port, args.baud)
    except Exception as e:
        bad(f"打不开串口 {port}: {e}")
        sys.exit(1)

    cap = UartCapture(ser, os.path.join(logdir, "uart.log"))
    time.sleep(0.3)

    # ---- 烧写 bit ----
    if not args.no_program:
        env = {"HW_SERVER_URL": args.hw_server, "BIT_FILE": args.bit}
        rc, out = run_vivado(os.path.join(ROOT, "program_current_hw.tcl"), env,
                             "烧写 bitstream",
                             os.path.join(logdir, "program-bit.log"), 420)
        if rc != 0 or "PROGRAM_DONE" not in out:
            bad("bitstream 烧写失败，详见日志")
            results["bitstream"] = False
        else:
            ok("bitstream 烧写完成")
            results["bitstream"] = True
            time.sleep(3)
    else:
        host("--no-program：跳过烧写（复用板子当前 bit）")

    # ---- 第一幕：bootloader ----
    if args.acts in ("bootloader", "both"):
        results["act1_bootloader"] = act_bootloader(args, cap, logdir)

    # ---- 第二幕：ucore 启动 ----
    if args.acts in ("ucore", "both"):
        results["act2_ucore_boot"] = act_ucore_boot(args, cap, logdir)

    ucore_ok = results.get("act2_ucore_boot") is True

    # ---- 第三幕：shell 功能演示 ----
    if args.scripted and ucore_ok:
        results["act3_shell"] = act_scripted(args, cap)

    # ---- 第四幕：UART 文件传输 ----
    if args.transfer and ucore_ok:
        results["act4_transfer"] = act_transfer(args, cap, logdir)

    # ---- 第五幕：交互 ----
    want_interactive = args.interactive
    if not args.no_interactive and not args.interactive and sys.stdin.isatty():
        try:
            ans = input(color(C_BOLD, "进入交互 shell？(y/N) ")).strip().lower()
            want_interactive = ans in ("y", "yes")
        except (EOFError, KeyboardInterrupt):
            want_interactive = False
    if want_interactive and ucore_ok:
        act_interactive(args, cap)

    # ---- 总结 ----
    banner("总结")
    if not results:
        bad("没有执行任何演示幕")
        rc = 1
    elif all(results.values()):
        ok(f"全部演示通过：{', '.join(results)}")
        rc = 0
    else:
        for k, v in results.items():
            (ok if v else bad)(f"{k}: {'PASS' if v else 'FAIL'}")
        rc = 1
    LOG.log(f"完整日志目录: {logdir}")
    cap.close()
    ser.close()
    LOG.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
