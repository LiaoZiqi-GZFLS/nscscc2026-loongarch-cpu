#!/bin/bash
# mkrootfs.sh — 生成 LA32R busybox 最小根文件系统（initramfs 清单 + cpio.gz）
# 用法: ./mkrootfs.sh <busybox二进制> <输出目录>
# 产物:
#   <输出目录>/initramfs_list.txt  内核 CONFIG_INITRAMFS_SOURCE 可直接引用
#   <输出目录>/rootfs.cpio.gz      独立 initrd（外挂 initrd 启动方案用）
# 依赖: gen_init_cpio（由内核源码 usr/gen_init_cpio.c 用 host gcc 编译，
#       build.sh 自动完成；也可用环境变量 GEN_INIT_CPIO 指定）
set -e
BUSYBOX=${1:?usage: mkrootfs.sh <busybox> <outdir>}
OUT=${2:?usage: mkrootfs.sh <busybox> <outdir>}
HERE=$(cd "$(dirname "$0")" && pwd)
GEN_INIT_CPIO=${GEN_INIT_CPIO:-$HERE/gen_init_cpio}
# 无预编译二进制时用自带源码（内核 usr/gen_init_cpio.c 副本）现场编译
if [ ! -x "$GEN_INIT_CPIO" ] && [ -f "$HERE/gen_init_cpio.c" ]; then
	gcc -O2 -o "$GEN_INIT_CPIO" "$HERE/gen_init_cpio.c"
fi
[ -x "$GEN_INIT_CPIO" ] || { echo "gen_init_cpio not found/executable: $GEN_INIT_CPIO"; exit 1; }

mkdir -p "$OUT"
LIST="$OUT/initramfs_list.txt"

{
cat <<'EOF'
dir  /bin   755 0 0
dir  /sbin  755 0 0
dir  /dev   755 0 0
dir  /proc  755 0 0
dir  /sys   755 0 0
dir  /etc   755 0 0
dir  /tmp   755 0 0
dir  /mnt   755 0 0
nod  /dev/console 600 0 0 c 5 1
nod  /dev/null    666 0 0 c 1 3
nod  /dev/ttyS0   600 0 0 c 4 64
EOF
echo "file /bin/busybox $BUSYBOX 755 0 0"
echo "file /init $HERE/rootfs/init 755 0 0"
# 常用 applet 软链接（init 脚本里还有 busybox --install 兜底）
for a in sh ls mount cat echo ps pwd mkdir cp mv rm dmesg uname hostname env ln chmod sync reboot poweroff free vi clear grep find; do
	echo "slink /bin/$a /bin/busybox 777 0 0"
done
echo "slink /sbin/init /bin/busybox 777 0 0"
} > "$LIST"

"$GEN_INIT_CPIO" "$LIST" | gzip -9 > "$OUT/rootfs.cpio.gz"
echo "generated: $LIST"
echo "generated: $OUT/rootfs.cpio.gz ($(stat -c%s "$OUT/rootfs.cpio.gz") bytes)"
