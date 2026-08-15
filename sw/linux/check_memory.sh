#!/bin/sh
# Check that the selected Linux image fits the target RAM window.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VARIANT=${1:-board-16m}
RAM_SIZE=${RAM_SIZE:-16777216}
RAM_BASE=${RAM_BASE:-0x1c000000}
KERNEL_ADDR=${KERNEL_ADDR:-0x1c300000}
RESERVE=${RESERVE:-4194304}
OUT="$HERE/out/$VARIANT"
ROOTFS=${ROOTFS:-$HERE/out/rootfs.cpio.gz}
INITRD_ADDR=${INITRD_ADDR:-0x1ca00000}

case "$RAM_BASE" in
  0x*) BASE=$((RAM_BASE)) ;;
  *) BASE=$RAM_BASE ;;
esac
case "$KERNEL_ADDR" in
  0x*) KADDR=$((KERNEL_ADDR)) ;;
  *) KADDR=$KERNEL_ADDR ;;
esac
case "$INITRD_ADDR" in
  0x*) IADDR=$((INITRD_ADDR)) ;;
  *) IADDR=$INITRD_ADDR ;;
esac

[ -d "$OUT" ] || { echo "ERROR: output directory not found: $OUT" >&2; exit 1; }
[ -f "$OUT/start.bin" ] || { echo "ERROR: missing $OUT/start.bin" >&2; exit 1; }
[ -f "$OUT/vmlinux.bin" ] || { echo "ERROR: missing $OUT/vmlinux.bin" >&2; exit 1; }

start_size=$(stat -c %s "$OUT/start.bin")
kernel_size=$(stat -c %s "$OUT/vmlinux.bin")
kernel_mem_size=$kernel_size
if [ -f "$OUT/vmlinux" ] && command -v readelf >/dev/null 2>&1; then
  elf_mem_size=$(readelf -lW "$OUT/vmlinux" 2>/dev/null | awk '$1 == "LOAD" {print $6; exit}')
  [ -n "$elf_mem_size" ] && kernel_mem_size=$((elf_mem_size))
fi
start_end=$((BASE + start_size))
kernel_end=$((KADDR + kernel_mem_size))
ram_end=$((BASE + RAM_SIZE))
used_end=$kernel_end
[ "$start_end" -gt "$used_end" ] && used_end=$start_end
free=$((ram_end - used_end))
rootfs_size=0
rootfs_file_size=0
if [ -f "$ROOTFS" ] && command -v gzip >/dev/null 2>&1; then
  rootfs_file_size=$(stat -c %s "$ROOTFS")
  rootfs_size=$(gzip -l "$ROOTFS" | awk 'NR == 2 {print $2}')
fi
initrd_end=$((IADDR + rootfs_file_size))
runtime_free=$((free - rootfs_size))

printf 'memory-check variant=%s ram=[0x%08x,0x%08x)\n' "$VARIANT" "$BASE" "$ram_end"
printf 'memory-check start=0x%x+%d kernel=0x%x+%d (memory=%d)\n' "$BASE" "$start_size" "$KADDR" "$kernel_size" "$kernel_mem_size"
printf 'memory-check image_end=0x%08x free_after_image=%d reserve=%d\n' "$used_end" "$free" "$RESERVE"
printf 'memory-check initramfs_unpacked=%d estimated_runtime_free=%d\n' "$rootfs_size" "$runtime_free"
printf 'memory-check initrd=0x%08x+%d end=0x%08x\n' "$IADDR" "$rootfs_file_size" "$initrd_end"

if [ "$start_end" -gt "$ram_end" ] || [ "$kernel_end" -gt "$ram_end" ]; then
  echo "ERROR: Linux image exceeds the target RAM window" >&2
  exit 1
fi
if [ "$KADDR" -lt "$BASE" ] || [ "$KADDR" -ge "$ram_end" ]; then
  echo "ERROR: kernel load address is outside the target RAM window" >&2
  exit 1
fi
if [ "$rootfs_file_size" -gt 0 ] && { [ "$IADDR" -lt "$kernel_end" ] || [ "$initrd_end" -gt "$ram_end" ]; }; then
  echo "ERROR: external initrd overlaps the kernel or exceeds target RAM" >&2
  exit 1
fi
if [ "$runtime_free" -lt "$RESERVE" ]; then
  echo "ERROR: insufficient RAM: need at least $RESERVE bytes after images and unpacked initramfs" >&2
  exit 1
fi
echo "memory-check PASS"
