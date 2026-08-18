#!/bin/sh
# 2026-final: chiplab/nscscc adaptation - reproducible ucore build for the
# LA32R NOP core + chiplab nscscc-team SoC.
#
# Usage:
#   ./build.sh            # full build + verify, artifacts in out/
#   TC=/path/to/la32r ./build.sh   # override toolchain location
set -e
cd "$(dirname "$0")"

# LA32R gnusf toolchain (gcc 8.3, ilp32s soft-float). Restore with:
#   mkdir -p /home/kimi/tc && cd /home/kimi/tc &&
#   tar xf /mnt/agents/work/toolchain/tc.tar.xz &&
#   mv loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0 la32r
if [ -z "${TC:-}" ]; then
    if [ -x /home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf-gcc ]; then
        TC=/home/kimi/tc/la32r
    elif [ -x /mnt/wslg/distro/tmp/opencode/la32r-tc/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin/loongarch32r-linux-gnusf-gcc ]; then
        TC=/mnt/wslg/distro/tmp/opencode/la32r-tc/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
    elif [ -x /home/cjy/chiplab/toolchains/loongarch32r-linux-gnusf-2022-05-20/bin/loongarch32r-linux-gnusf-gcc ]; then
        TC=/home/cjy/chiplab/toolchains/loongarch32r-linux-gnusf-2022-05-20
    else
        echo "LA32R toolchain not found; set TC=/path/to/toolchain" >&2
        exit 1
    fi
fi
export PATH="$TC/bin:$PATH"
PFX=loongarch32r-linux-gnusf-

intrin=$(${PFX}gcc -print-file-name=include)/larchintrin.h
CSR_DEF=
if grep -q '__builtin_loongarch_csrrd_w' "$intrin"; then
    CSR_DEF=-DUCORE_CSR_BUILTIN_SUFFIX_W
fi

# ON_FPGA=y selects the small app set (sh ls cat) and a 700-sector initrd
# that comfortably fits the 16MB chiplab DDR window together with the kernel.
make clean
make ON_FPGA=y MACH_DEF="$CSR_DEF"

mkdir -p out
cp obj/ucore-kernel-initrd out/ucore.elf
${PFX}objcopy -O binary obj/ucore-kernel-initrd out/ucore.bin
${PFX}strip -s obj/ucore-kernel-initrd -o out/ucore.elf.stripped

echo "==== verify ===="
readelf -h out/ucore.elf | grep -E 'Class|Type|Machine|Entry'
${PFX}objdump -d out/ucore.elf > out/ucore.asm
am=$(grep -cE '\bam(swap|add|and|or|xor|max|min|cas)(_[a-z]+)?\.(w|d|b|h)\b' out/ucore.asm || true)
fp=$(grep -cE '\bf(add|sub|mul|div|madd|msub|nmadd|nmsub|max|min|sqrt|recip|rsqrt|mov|cvt|cmp|ld|st|intrz|sel|class)\.[sd]\b|\b(movgr2fr|movfr2gr|movgr2fcsr|movfcsr2gr|fcmp)\.' out/ucore.asm || true)
echo "AM atomic instructions in image: $am (must be 0, LA32R has no AM*)"
echo "FP instructions in image:        $fp (must be 0, LA32R has no FPU)"
ls -l out/ucore.elf out/ucore.bin
