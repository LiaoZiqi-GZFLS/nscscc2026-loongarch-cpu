#!/bin/bash
# mkimage.sh — 由 vmlinux 生成上板/仿真所需镜像
# 用法: ./mkimage.sh <vmlinux> <输出目录>
# 产物（输出目录下）:
#   vmlinux.bin  内核裸二进制（.text/.rodata/.data/.init.* 等段）
#   start.bin    引导 stub（复位向量 0x1c000000）
#   rom.vlog     verilator RAM 初始化文件（start.bin@0x1c000000 + vmlinux.bin@物理加载地址）
set -e
TC=${CROSS_COMPILE:-loongarch32r-linux-gnusf-}
VMLINUX=${1:?usage: mkimage.sh <vmlinux> <outdir>}
OUT=${2:?usage: mkimage.sh <vmlinux> <outdir>}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

KERNEL_ENTRY=$(${TC}readelf -s "$VMLINUX" | awk '/ kernel_entry$/{print "0x"$2; exit}')
[ -n "$KERNEL_ENTRY" ] || { echo "kernel_entry not found"; exit 1; }
echo "kernel_entry = $KERNEL_ENTRY"

# 引导 stub（链接到复位地址 0x1c000000；CMDLINE 可按需改）
CMDLINE=${CMDLINE:-"console=ttyS0,115200 rdinit=/init loglevel=8"}
${TC}gcc -DKERNEL_ENTRY_ADDRESS=$KERNEL_ENTRY -DCMDLINE="\"$CMDLINE\"" \
	-c "$HERE/start.S" -o "$OUT/start.o"
${TC}ld -Ttext=0x1c000000 -o "$OUT/start.elf" "$OUT/start.o"
${TC}objcopy -O binary -j .text "$OUT/start.elf" "$OUT/start.bin"

# 内核裸二进制（段清单与 chiplab 官方 script.sh 一致）
${TC}objcopy -O binary -j .text -j __ex_table -j .notes -j .rodata -j __param \
	-j .sdata -j __modver -j .data -j .data..page_aligned \
	-j .init.text -j .init.data -j .exit.text "$VMLINUX" "$OUT/vmlinux.bin"

# verilator RAM 初始化文件
python3 - "$VMLINUX" "$OUT" <<'EOF'
import subprocess, sys, re
vmlinux, out = sys.argv[1], sys.argv[2]
# 内核物理加载地址 = .text vaddr - 直映窗口基址（0xa0000000 或 0x80000000）
hdr = subprocess.check_output(['readelf', '-S', vmlinux]).decode()
m = re.search(r'\.text\s+PROGBITS\s+([0-9a-f]+)', hdr)
vaddr = int(m.group(1), 16)
base = 0xa0000000 if vaddr >= 0xa0000000 else 0x80000000
phys = vaddr - base
print(f"vmlinux .text vaddr={vaddr:#x} phys={phys:#x}")
with open(f"{out}/rom.vlog", "w") as f:
    f.write("@1c000000\n")
    f.write(open(f"{out}/start.bin", "rb").read().hex('\n', 1) if False else
            '\n'.join(f"{b:02x}" for b in open(f"{out}/start.bin","rb").read()))
    f.write("\n@%x\n" % phys)
    f.write('\n'.join(f"{b:02x}" for b in open(f"{out}/vmlinux.bin","rb").read()))
    f.write("\n")
print("rom.vlog written")
EOF
echo "done: $OUT/{vmlinux.bin,start.bin,rom.vlog}"
