#!/usr/bin/env python3
import argparse
import binascii
import os
import select
import termios
import time


class Serial:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_SYNC)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
        attrs[3] = 0
        attrs[4] = termios.B115200
        attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 1
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def close(self):
        os.close(self.fd)

    def write_line(self, line):
        data = (line + "\r").encode("ascii")
        for byte in data:
            os.write(self.fd, bytes((byte,)))
            time.sleep(0.012)

    def read_line(self, timeout=10):
        deadline = time.monotonic() + timeout
        data = bytearray()
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], min(0.2, deadline - time.monotonic()))
            if not ready:
                continue
            chunk = os.read(self.fd, 1)
            if not chunk:
                continue
            if chunk in (b"\r", b"\n"):
                if data:
                    return data.decode("ascii", "replace")
                continue
            data.extend(chunk)
        raise TimeoutError("UART response timed out")

    def wait_prefix(self, prefix, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.read_line(max(0.1, deadline - time.monotonic()))
            print(f"< {line}")
            if line.startswith("XERR") or line.startswith("error:"):
                raise RuntimeError(line)
            if line.startswith(prefix):
                return line
        raise TimeoutError(f"UART did not send {prefix!r}")


def crc32(data):
    return binascii.crc32(data) & 0xFFFFFFFF


def upload(serial, local_path, remote_path):
    with open(local_path, "rb") as source:
        data = source.read()
    serial.write_line(f"xput {remote_path} {len(data)} {crc32(data):08X}")
    serial.wait_prefix("XREADY PUT")
    for seq, offset in enumerate(range(0, len(data), 128)):
        chunk = data[offset:offset + 128]
        line = f"D {seq} {len(chunk)} {crc32(chunk):08X} {chunk.hex().upper()}"
        for attempt in range(3):
            serial.write_line(line)
            try:
                serial.wait_prefix(f"ACK {seq}", 5)
                break
            except TimeoutError:
                if attempt == 2:
                    raise
        print(f"uploaded {offset + len(chunk)}/{len(data)} bytes")
    serial.wait_prefix("XDONE")


def download(serial, remote_path, local_path):
    serial.write_line(f"xget {remote_path}")
    meta = serial.wait_prefix("XMETA")
    _, size_text, crc_text = meta.split()
    expected_size = int(size_text)
    expected_crc = int(crc_text, 16)
    data = bytearray()
    seq = 0
    while len(data) < expected_size:
        line = serial.wait_prefix("D ")
        _, seq_text, length_text, chunk_crc_text, hex_data = line.split()
        if int(seq_text) != seq:
            raise RuntimeError(f"unexpected sequence {seq_text}, wanted {seq}")
        chunk = bytes.fromhex(hex_data)
        if len(chunk) != int(length_text) or crc32(chunk) != int(chunk_crc_text, 16):
            raise RuntimeError(f"chunk {seq} failed validation")
        data.extend(chunk)
        serial.write_line(f"ACK {seq}")
        seq += 1
        print(f"downloaded {len(data)}/{expected_size} bytes")
    serial.wait_prefix("XDONE")
    if len(data) != expected_size or crc32(data) != expected_crc:
        raise RuntimeError("download failed whole-file validation")
    with open(local_path, "wb") as output:
        output.write(data)


def main():
    parser = argparse.ArgumentParser(description="Transfer files to and from uCore over UART")
    parser.add_argument("--port", default="/dev/ttyUSB0")
    subparsers = parser.add_subparsers(dest="command", required=True)
    put = subparsers.add_parser("put")
    put.add_argument("local")
    put.add_argument("remote")
    get = subparsers.add_parser("get")
    get.add_argument("remote")
    get.add_argument("local")
    args = parser.parse_args()

    serial = Serial(args.port)
    try:
        if args.command == "put":
            upload(serial, args.local, args.remote)
        else:
            download(serial, args.remote, args.local)
    finally:
        serial.close()


if __name__ == "__main__":
    main()
