#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_offboard.py — demo.py 不上板自检

用脚本化的"假板"（FakeSerial）模拟真实串口行为（输入回显、ucore shell
响应、UART 文件传输协议），并把 Vivado/hw_server 打桩为假实现，完整跑通
demo.py 的五幕流程，断言各幕 PASS。不需要开发板、Vivado 或串口。

用法：
  python test_offboard.py

检查项：
  Phase 1  完整流程（烧 bit → 第一幕 bootloader → 第二幕 ucore 启动 →
           第三幕 shell 演示 → 第四幕 UART 文件传输），断言 4 幕全 PASS；
  Phase 2  --no-program --no-load 观察模式（板端输出已在串口流中），
           断言第二幕仍 PASS。
"""
import io
import os
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demo

# --------------------------------------------------------------------------
# 假板：模拟串口 + ucore shell + 传输协议
# --------------------------------------------------------------------------
def crc32_hex(data):
    return format(demo.crc32(data), "08X")


class FakeSerial:
    def __init__(self):
        self.lock = threading.Lock()
        self.outq = []            # [(due_time, bytes)]
        self.buf = bytearray()    # 尚未被主机读走的余量
        self.inbuf = bytearray()
        self.stored = {}          # remote -> bytes（xput 写入的文件）
        self.uploading = None     # xput 进行中: dict(remote,size,data)
        self.getting = None       # xget 进行中: dict(data,next)

    # ---- 主机侧接口（demo.py 调用）----
    def read(self, n):
        now = time.monotonic()
        with self.lock:
            due = [d for t, d in self.outq if t <= now]
            self.outq = [(t, d) for t, d in self.outq if t > now]
            self.buf.extend(b"".join(due))
            data = bytes(self.buf[:n])
            del self.buf[:n]
            return data

    def write(self, data):
        with self.lock:
            self._send_locked(data.replace(b"\r", b"\r\n"))  # 真实终端回显
            self.inbuf.extend(data)
            while b"\r" in self.inbuf:
                line, _, self.inbuf = self.inbuf.partition(b"\r")
                if self.inbuf[:1] == b"\n":
                    del self.inbuf[:1]
                self._handle_line_locked(bytes(line).strip())

    def flushInput(self):
        with self.lock:
            self.inbuf.clear()

    def close(self):
        pass

    # ---- 板端输出 ----
    def play(self, data, delay=0.3):
        with self.lock:
            self.outq.append((time.monotonic() + delay, data))

    def _send_locked(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.outq.append((time.monotonic(), data))

    def _send(self, data):
        with self.lock:
            self._send_locked(data)

    # ---- 命令处理（模拟 ucore sh + 传输协议）----
    def _handle_line_locked(self, line):
        parts = line.split()
        if not parts:
            self._send_locked("\n$ ")
            return
        cmd = parts[0].decode()
        if cmd == "xput":
            remote, size = parts[1].decode(), int(parts[2])
            self.uploading = {"remote": remote, "size": size, "data": bytearray()}
            self._send_locked("XREADY PUT\r\n")
        elif cmd == "D" and self.uploading:
            seq, ln, hexs = int(parts[1]), int(parts[2]), parts[4]
            chunk = bytes.fromhex(hexs.decode())
            assert len(chunk) == ln, "fake board: chunk length mismatch"
            self.uploading["data"].extend(chunk)
            self._send_locked(f"ACK {seq}\r\n")
            if len(self.uploading["data"]) >= self.uploading["size"]:
                data = bytes(self.uploading["data"][:self.uploading["size"]])
                self.stored[self.uploading["remote"]] = data
                self.uploading = None
                self._send_locked("XDONE\r\n$ ")
        elif cmd == "xget":
            remote = parts[1].decode()
            data = self.stored[remote]
            self.getting = {"data": data, "next": 0}
            self._send_locked(f"XMETA {len(data)} {crc32_hex(data)}\r\n")
            self._send_next_chunk_locked()
        elif cmd == "ACK" and self.getting:
            self._send_next_chunk_locked()
        elif cmd == "cat":
            data = self.stored.get(parts[1].decode(), b"")
            self._send_locked(data.decode("ascii", "replace") + "\n$ ")
        else:
            self._send_locked(self._shell_reply(line) + "$ ")

    def _send_next_chunk_locked(self):
        g = self.getting
        off = g["next"] * 128
        if off >= len(g["data"]):
            self.getting = None
            self._send_locked("XDONE\r\n$ ")
            return
        chunk = g["data"][off:off + 128]
        self._send_locked(
            f"D {g['next']} {len(chunk)} {crc32_hex(chunk)} "
            f"{chunk.hex().upper()}\r\n")
        g["next"] += 1

    def _shell_reply(self, line):
        parts = line.decode().split()
        cmd = parts[0]
        if cmd == "help":
            return ("usage: help pwd ls mkdir cd write cat stat cp mv rm display\n"
                    "xput/xget: UART file transfer\n")
        if cmd == "pwd":
            return "/\n"
        if cmd == "ls":
            return "demo\nhello.txt\n"
        if cmd == "stat":
            return ("  File: hello.txt\n  Size: 19 Bytes\n  Type: File\n"
                    "  Inode: 100\n  Links: 1\n")
        if cmd == "write":
            text = b" ".join(line.split()[2:])
            self.stored[parts[1]] = text
            return ""
        if cmd == "display":
            return ""
        return ""


# --------------------------------------------------------------------------
# 板端输出剧本（覆盖 demo.py 的全部解说标记）
# --------------------------------------------------------------------------
ACT1_STREAM = (
    b"\r\nNSCSCC2026 mini bootloader v0.1 (LA32R/chiplab)\r\n"
    b"DDR      : 0x1c000000 size 16 MB\r\n"
    b"UART     : 0x1fe001e0 pclk 100 MHz, 115200 8N1 (div=54)\r\n"
    b"Image    : probe 0x1c400000\r\n"
    b"  LOAD 0x1c200000 filesz=0x00000fb8 memsz=0x00001fd0\r\n"
    b"fw_arg   : argc=2 argv=0xbcff0000 bpi=0xbcff0140\r\n"
    b"cmdline  : console=ttyS0,115200\r\n"
    b"MEM list : SYSRAM 0x1c000000 size 0x01000000\r\n"
    b"Jumping to entry 0xbc200000 ...\r\n\r\n"
    b"==============================\r\n"
    b" NSCSCC2026 demo payload v1.0\r\n"
    b"==============================\r\n"
    b"linked  : 0xbc200000 (phys 0x1c200000)\r\n"
    b"loaded  : by NSCSCC2026 mini bootloader from staging 0x1c400000\r\n"
    b"fw_arg handoff:\r\n  argc = 2\r\n"
    b"  argv[0] = 0xbcff0020 -> \"boot\"\r\n"
    b"  argv[1] = 0xbcff0040 -> \"console=ttyS0,115200\"\r\n"
    b"  bpi  = 0xbcff0140 sig=\"BPI01000\"\r\n"
    b"  MEM node: sig=\"MEM\" len=43 rev=0 next=0x00000000 checksum=0 OK\r\n"
    b"  memory map (2 entries):\r\n"
    b"    map[0] type=SYSRAM start=0x1c000000 size=0x01000000\r\n"
    b"    map[1] type=RESERVED start=0x1cff0000 size=0x00010000\r\n"
    b"PAYLOAD_OK\r\n"
)

ACT2_STREAM = (
    b"(THU.CST) os is loading ...\r\n\r\n"
    b"Special kernel symbols:\r\n"
    b"  entry  0xBC000134 (phys)\r\n"
    b"Kernel executable memory footprint: 647KB\r\n"
    b"memory management: default_pmm_manager\r\n"
    b"check_alloc_page() succeeded!\r\n"
    b"check_pgdir() succeeded!\r\n"
    b"check_boot_pgdir() succeeded!\r\n"
    b"check_slab() succeeded!\r\n"
    b"check_vma_struct() succeeded!\r\n"
    b"check_vmm() succeeded.\r\n"
    b"sched class: stride_scheduler\r\n"
    b"proc_init succeeded\r\n"
    b"Initrd: 0xbc060200 - 0xbc0b79ff, size: 0x00057800\r\n"
    b"sfs: mount: 'simple file system' (71/16/87)\r\n"
    b"vfs: mount disk0.\r\n"
    b"kernel_execve: pid = 2, name = \"sh\".\r\n"
    b"user sh is running!!!\r\n$ "
)


class FakeVivado:
    """打桩 demo.run_vivado：按 TCL/环境变量返回对应标记并触发板端剧本。"""

    def __init__(self, board):
        self.board = board
        self.calls = []

    def __call__(self, tcl_path, env, step_name, log_path, timeout):
        self.calls.append(os.path.basename(tcl_path))
        if "program_current_hw" in tcl_path:
            out = "PROGRAM_DONE=bitfile"
        elif "load_demo.tcl" in tcl_path:
            if env.get("RESET_ONLY") == "1":
                out = "DEMO_RESET_HELD"
            elif env.get("IMAGE1"):
                self.board.play(ACT1_STREAM)
                out = "DEMO_LOAD_DONE\nDEMO_CPU_RELEASED"
            else:
                self.board.play(ACT2_STREAM)
                out = "DEMO_LOAD_DONE\nDEMO_CPU_RELEASED"
        else:
            out = ""
        demo.LOG.log(f"  | (fake) {step_name}")
        return 0, out


def run_phase(argv, dummies, preseed=None):
    """以给定 argv 跑一遍 demo.main()，返回 (退出码, 输出文本)。
    preseed: 打开串口前预灌到板端输出流的字节（模拟"板子已在运行"）。"""
    old = (demo.open_serial, demo.run_vivado, demo.ensure_hw_server,
           demo.find_uart_port, sys.argv, sys.stdout)
    captured = io.StringIO()
    board = FakeSerial()
    if preseed:
        board.play(preseed, delay=0)
    demo.open_serial = lambda port, baud=115200: board
    demo.run_vivado = FakeVivado(board)
    demo.ensure_hw_server = lambda url, start=False: True
    demo.find_uart_port = lambda: "FAKE"
    sys.argv = argv
    sys.stdout = captured
    rc = 1
    try:
        demo.main()
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 1
    finally:
        (demo.open_serial, demo.run_vivado, demo.ensure_hw_server,
         demo.find_uart_port, sys.argv, sys.stdout) = old
    return rc, captured.getvalue()


def main():
    fails = 0

    # 临时目录放日志与假镜像
    tmp = tempfile.mkdtemp(prefix="demo-offboard-")
    logdir = os.path.join(tmp, "logs")
    # 只在真实镜像缺失时创建占位假镜像（测试结束只删除占位，不碰真实产物）
    dummies = {}
    for name in ("boot.bin", "demo_payload.elf"):
        path = os.path.join(demo.BOOT_DIR, name)
        if not os.path.exists(path):
            with open(path, "wb") as f:
                f.write(b"")
            dummies[path] = True

    base = ["demo.py", "--port", "FAKE", "--no-build",
            "--cmd-delay", "0.001", "--char-delay", "0.001",
            "--act1-timeout", "30", "--act2-timeout", "30",
            "--cmd-timeout", "10", "--no-interactive",
            "--log-dir", logdir]

    # ---- Phase 1：完整五幕流程 ----
    rc, out = run_phase(base[:], dummies)
    checks = ["第一幕 PASS", "第二幕 PASS", "第三幕 PASS", "第四幕 PASS",
              "全部演示通过"]
    print("Phase 1 完整流程:")
    for c in checks:
        mark = "OK " if c in out else "FAIL"
        if c not in out:
            fails += 1
        print(f"  [{mark}] {c}")
    if rc != 0:
        fails += 1
        print(f"  [FAIL] 退出码 {rc}（期望 0）")
    else:
        print("  [OK ] 退出码 0")
    # 关键协议细节：传输文件内容必须逐字节一致
    src = os.path.join(logdir, "transfer-src.bin")
    dst = os.path.join(logdir, "transfer-dst.bin")
    if os.path.exists(src) and os.path.exists(dst) and \
            open(src, "rb").read() == open(dst, "rb").read():
        print("  [OK ] transfer-src.bin == transfer-dst.bin（256 字节一致）")
    else:
        fails += 1
        print("  [FAIL] 往返文件不一致或缺失")

    # ---- Phase 2：--no-program --no-load 观察模式（已启动的板子）----
    logdir2 = os.path.join(tmp, "logs2")
    rc, out = run_phase(base[:] + ["--no-program", "--no-load",
                                   "--no-scripted", "--no-transfer",
                                   "--acts", "ucore",
                                   "--log-dir", logdir2],
                        dummies, preseed=ACT2_STREAM)
    print("Phase 2 观察模式（--no-program --no-load）:")
    if "第二幕 PASS" in out and rc == 0:
        print("  [OK ] 第二幕 PASS（已启动板子直接观察）")
    else:
        fails += 1
        print(f"  [FAIL] rc={rc}，输出中含「第二幕 PASS」= {'第二幕 PASS' in out}")

    # ---- Phase 3：故障路径（板端 BOOT FAILED 应快速失败并退出码 1）----
    logdir3 = os.path.join(tmp, "logs3")
    rc, out = run_phase(base[:] + ["--acts", "bootloader", "--no-transfer",
                                   "--no-scripted", "--log-dir", logdir3],
                        dummies, preseed=b"NSCSCC2026 mini bootloader v0.1\r\n"
                        b"Image    : probe 0x1c400000\r\nBOOT FAILED: halt\r\n")
    print("Phase 3 故障路径（板端 BOOT FAILED）:")
    if "第一幕" in out and "FAIL" in out and rc != 0:
        print("  [OK ] 快速失败并返回非零退出码")
    else:
        fails += 1
        print(f"  [FAIL] rc={rc}，期望非零且第一幕 FAIL")

    # 清理占位假镜像与临时目录
    for path in dummies:
        try:
            os.remove(path)
        except OSError:
            pass
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print()
    if fails:
        print(f"自检结果: {fails} 项失败 ❌")
        return 1
    print("自检结果: 全部通过 ✅（demo.py 五幕流程在上板前验证无误）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
