#!/bin/bash
# build.sh — T2026143250012561 LA32R Linux + busybox initramfs 一键构建
#
# 流程: 克隆内核 -> 打补丁 -> la32_defconfig -> busybox 静态编译
#       -> 生成 initramfs 清单/独立 initrd -> 内嵌 initramfs 编译内核
#       -> 生成 vmlinux.bin / start.bin / rom.vlog -> 验收检查
#
# 用法: ./build.sh [工作目录]        （默认 ./work）
# 环境变量:
#   CROSS_COMPILE   交叉工具链前缀（默认 loongarch32r-linux-gnusf-，须在 PATH）
#   KERNEL_URL      内核仓库（默认 https://gitee.com/loongson-edu/la32r-Linux.git）
#   KERNEL_COMMIT   内核 commit（默认 4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e）
#   BUSYBOX_URL     busybox 源码包（默认 1.36.1）
#   CMDLINE         内核命令行（默认 "console=ttyS0,115200 rdinit=/init loglevel=8"）
#   JOBS            并行度（默认 nproc）
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-$HERE/work}
CROSS_COMPILE=${CROSS_COMPILE:-loongarch32r-linux-gnusf-}
KERNEL_URL=${KERNEL_URL:-https://gitee.com/loongson-edu/la32r-Linux.git}
KERNEL_COMMIT=${KERNEL_COMMIT:-4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e}
BUSYBOX_URL=${BUSYBOX_URL:-https://busybox.net/downloads/busybox-1.36.1.tar.bz2}
CMDLINE=${CMDLINE:-"console=ttyS0,115200 rdinit=/init loglevel=8"}
JOBS=${JOBS:-$(nproc)}

# host 依赖: gcc make flex bison bc perl python3 gzip git
for t in gcc make flex bison bc perl python3 gzip git; do
	command -v $t >/dev/null || { echo "缺少 host 依赖: $t"; exit 1; }
done
command -v ${CROSS_COMPILE}gcc >/dev/null || { echo "交叉工具链不在 PATH: $CROSS_COMPILE"; exit 1; }

mkdir -p "$WORK" "$HERE/out"
cd "$WORK"

# ---------- 1. 内核源码 ----------
if [ ! -d la32r-Linux ]; then
	git clone "$KERNEL_URL" la32r-Linux
fi
cd la32r-Linux
git checkout "$KERNEL_COMMIT"
# ---------- 2. 适配补丁 ----------
for p in "$HERE"/patches/*.patch; do
	[ -e "$p" ] || continue
	git apply --check "$p" 2>/dev/null && git apply "$p" && echo "applied: $p" \
		|| echo "skip（已应用或不适用）: $p"
done

# ---------- 3. busybox ----------
cd "$WORK"
[ -f busybox.tar.bz2 ] || curl -L -o busybox.tar.bz2 "$BUSYBOX_URL"
[ -d busybox-src ] || { mkdir busybox-src && tar xf busybox.tar.bz2 -C busybox-src --strip-components=1; }
cd busybox-src
[ -f .config ] || { make defconfig && sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config; }
make CROSS_COMPILE=$CROSS_COMPILE -j"$JOBS"

# ---------- 4. initramfs ----------
cd "$WORK"
[ -x gen_init_cpio ] || gcc -O2 -o gen_init_cpio la32r-Linux/usr/gen_init_cpio.c
GEN_INIT_CPIO=$WORK/gen_init_cpio "$HERE/mkrootfs.sh" "$WORK/busybox-src/busybox" "$WORK/initramfs"

# ---------- 5. 内核 ----------
cd "$WORK/la32r-Linux"
make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE la32_defconfig
sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$WORK/initramfs/initramfs_list.txt\"|" .config
make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE olddefconfig
make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE -j"$JOBS"

# ---------- 6. 镜像与产物 ----------
"$HERE/boot/mkimage.sh" "$WORK/la32r-Linux/vmlinux" "$WORK/image"
${CROSS_COMPILE}strip -o "$HERE/out/vmlinux" "$WORK/la32r-Linux/vmlinux"
cp "$WORK/image/vmlinux.bin"        "$HERE/out/vmlinux.bin"
cp "$WORK/image/start.bin"          "$HERE/out/start.bin"
cp "$WORK/initramfs/rootfs.cpio.gz" "$HERE/out/rootfs.cpio.gz"
cp "$WORK/initramfs/initramfs_list.txt" "$HERE/out/"
cp "$WORK/busybox-src/busybox"      "$HERE/out/busybox"
cp "$WORK/la32r-Linux/.config"      "$HERE/out/kernel.config"

# ---------- 7. 验收 ----------
echo "==== 验收 ===="
${CROSS_COMPILE}readelf -h "$HERE/out/vmlinux" | grep -E 'Class|Machine|Type|Entry'
AM=$(${CROSS_COMPILE}objdump -d "$HERE/out/vmlinux" | grep -cE '\bam(swap|add|and|or|xor|max|min|cas)' || true)
echo "AM 原子指令条数: $AM （必须为 0）"
ls -l "$HERE/out"
