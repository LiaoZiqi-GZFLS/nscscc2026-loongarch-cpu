#!/bin/bash
# build.sh — T2026143250012561 LA32R chiplab Linux 双变体一键构建
#
# 变体:
#   verilator-flow  chiplab verilator 官方流程（RAM: 物理0起128MB, 内核@0x300000）
#   board-16m       nscscc-team 最小 SoC 上板（DDR 16MB@0x1c000000,
#                   内核链接/加载 @物理0x1c300000=虚址0xbc300000, 裁剪配置）
#
# 用法: ./build.sh [verilator|board-16m|all] [工作目录]
# 环境变量: CROSS_COMPILE / KERNEL_URL / KERNEL_COMMIT / BUSYBOX_URL / CMDLINE / JOBS
# 详见 README.md
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
VARIANT=${1:-all}
WORK=${2:-$HERE/work}
CROSS_COMPILE=${CROSS_COMPILE:-loongarch32r-linux-gnusf-}
KERNEL_URL=${KERNEL_URL:-https://gitee.com/loongson-edu/la32r-Linux.git}
KERNEL_COMMIT=${KERNEL_COMMIT:-4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e}
BUSYBOX_URL=${BUSYBOX_URL:-https://busybox.net/downloads/busybox-1.36.1.tar.bz2}
CMDLINE=${CMDLINE:-"console=ttyS0,115200 rdinit=/init loglevel=8"}
JOBS=${JOBS:-$(nproc)}

for t in gcc make flex bison bc perl python3 gzip git curl; do
	command -v $t >/dev/null || { echo "缺少 host 依赖: $t"; exit 1; }
done
command -v ${CROSS_COMPILE}gcc >/dev/null || { echo "交叉工具链不在 PATH: $CROSS_COMPILE"; exit 1; }

mkdir -p "$WORK"
cd "$WORK"

# ---------- 1. 内核源码 + 共享补丁（0001~0003） ----------
if [ ! -d la32r-Linux ]; then
	git clone "$KERNEL_URL" la32r-Linux
	cd la32r-Linux && git checkout "$KERNEL_COMMIT"
else
	cd la32r-Linux
fi
for p in "$HERE"/patches/000[1235678]*.patch; do
	git apply --check "$p" 2>/dev/null && git apply "$p" && echo "applied: $(basename $p)" \
		|| echo "skip（已应用）: $(basename $p)"
done
cd "$WORK"

# ---------- 2. busybox ----------
[ -f busybox.tar.bz2 ] || curl -L -o busybox.tar.bz2 "$BUSYBOX_URL"
[ -d busybox-src ] || { mkdir busybox-src && tar xf busybox.tar.bz2 -C busybox-src --strip-components=1; }
cd busybox-src
[ -f .config ] || { make defconfig && sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config; }
make CROSS_COMPILE=$CROSS_COMPILE -j"$JOBS"
cd "$WORK"

# ---------- 3. initramfs（两变体共用） ----------
[ -x gen_init_cpio ] || gcc -O2 -o gen_init_cpio la32r-Linux/usr/gen_init_cpio.c
GEN_INIT_CPIO=$WORK/gen_init_cpio "$HERE/mkrootfs.sh" "$WORK/busybox-src/busybox" "$WORK/initramfs"

build_one() { # $1=变体名 $2=源码树 $3=额外 make 参数 $4=配置后处理脚本
	local V=$1 SRC=$2 EXTRA=$3 FRAG=$4
	local O="$HERE/out/$V"
	mkdir -p "$O"
	cd "$WORK/$SRC"
	make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE la32_defconfig
	if [ -n "$FRAG" ]; then
		scripts/kconfig/merge_config.sh -m .config "$FRAG"
	fi
	sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$WORK/initramfs/initramfs_list.txt\"|" .config
	make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE olddefconfig
	make ARCH=loongarch CROSS_COMPILE=$CROSS_COMPILE $EXTRA -j"$JOBS"
	"$HERE/boot/mkimage.sh" "$WORK/$SRC/vmlinux" "$WORK/image-$V"
	${CROSS_COMPILE}strip -o "$O/vmlinux" "$WORK/$SRC/vmlinux"
	cp "$WORK/image-$V/vmlinux.bin" "$WORK/image-$V/start.bin" "$O/"
	cp .config "$O/kernel.config"
	${CROSS_COMPILE}readelf -h "$O/vmlinux" | grep -E 'Class|Machine|Type|Entry'
	local AM=$(${CROSS_COMPILE}objdump -d "$WORK/$SRC/vmlinux" | grep -cE '\bam(swap|add|and|or|xor|max|min|cas)' || true)
	echo "[$V] AM 原子指令条数: $AM （必须为 0）"
	ls -l "$O"
	cd "$WORK"
}

# ---------- 4. verilator-flow 变体 ----------
if [ "$VARIANT" = "verilator" ] || [ "$VARIANT" = "all" ]; then
	build_one verilator-flow la32r-Linux "" ""
fi

# ---------- 5. board-16m 变体（独立 worktree + 0004 补丁 + 裁剪配置 + 链接地址） ----------
if [ "$VARIANT" = "board-16m" ] || [ "$VARIANT" = "all" ]; then
	cd "$WORK/la32r-Linux"
	[ -d "$WORK/la32r-Linux-16m" ] || git worktree add "$WORK/la32r-Linux-16m" HEAD
	cd "$WORK/la32r-Linux-16m"
	for p in "$HERE"/patches/000[1-8]*.patch; do
		git apply --check "$p" 2>/dev/null && git apply "$p" && echo "applied: $(basename $p)" \
			|| echo "skip（已应用）: $(basename $p)"
	done
	build_one board-16m la32r-Linux-16m "CONFIG_PHYSICAL_START=0xbc300000" "$HERE/config/board-16m.fragment"
fi

# ---------- 6. 共用产物 ----------
cp "$WORK/initramfs/rootfs.cpio.gz" "$WORK/initramfs/initramfs_list.txt" "$HERE/out/"
cp "$WORK/busybox-src/busybox" "$HERE/out/busybox"
echo "==== 全部完成 ===="
