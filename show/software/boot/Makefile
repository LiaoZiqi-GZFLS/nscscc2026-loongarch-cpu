# Makefile - NSCSCC2026 mini bootloader (LA32R + chiplab)
#
# Toolchain: loongson-gnu-toolchain-8.3 (la32r, ilp32s soft-float)
#   /home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf-gcc
#
# Outputs: boot.elf (for objdump/debug) and boot.bin (for JTAG-AXI download)

# 自动探测常见工具链位置（与 sw/ucore/build.sh 的探测顺序一致）
CROSS_COMPILE ?= $(shell for p in \
  /home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf- \
  /home/cjy/chiplab/toolchains/loongarch32r-linux-gnusf-2022-05-20/bin/loongarch32r-linux-gnusf- \
  /home/lazybones/la32r/tc/loongarch32r-linux-gnusf-2022-05-20/bin/loongarch32r-linux-gnusf- \
  /mnt/wslg/distro/tmp/opencode/la32r-tc/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin/loongarch32r-linux-gnusf- \
  ; do [ -x "$${p}gcc" ] && echo "$$p" && break; done)
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump
READELF := $(CROSS_COMPILE)readelf

# -G0: no gp-relative addressing (we never init $gp)
CFLAGS  := -ffreestanding -nostdlib -nostdinc -fno-builtin -G0 \
           -fno-pic -msoft-float -O2 -Wall -Wextra -I.
ASFLAGS := $(CFLAGS)
LDFLAGS := -nostdlib -Wl,-T,linker.ld -Wl,--build-id=none

# Optional overrides, e.g.:
#   make EXTRA="-DUART_PCLK=33000000"        # different UART clock
#   make EXTRA="-DBOOT_RAW_BINARY"           # chain-load a bare bin
EXTRA   ?=

OBJS    := start.o main.o

all: boot.elf boot.bin

start.o: start.S boot.h
	$(CC) $(ASFLAGS) $(EXTRA) -c $< -o $@

main.o: main.c boot.h
	$(CC) $(CFLAGS) $(EXTRA) -c $< -o $@

boot.elf: $(OBJS) linker.ld
	$(CC) $(CFLAGS) $(OBJS) $(LDFLAGS) -o $@

boot.bin: boot.elf
	$(OBJCOPY) -O binary $< $@

# ---- demo payload (bootloader showcase target, finals demo) ----
# Linked at 0xbc200000 (-> phys 0x1c200000, clear of the bootloader).
# Loaded from staging 0x1c400000 by the bootloader's ELF loader; prints
# the fw_arg handoff and halts.  See sw/ucore/demo/DEMO.md.
demo_payload.elf: demo_start.o demo_payload.o demo_payload.ld
	$(CC) $(CFLAGS) demo_start.o demo_payload.o \
	    -nostdlib -Wl,-T,demo_payload.ld -Wl,--build-id=none -o $@

demo_start.o: demo_start.S boot.h
	$(CC) $(ASFLAGS) -c $< -o $@

demo_payload.o: demo_payload.c boot.h
	$(CC) $(CFLAGS) -c $< -o $@

payload: demo_payload.elf
	$(READELF) -h demo_payload.elf | grep -E 'Class|Machine|Entry'
	$(OBJDUMP) -d demo_payload.elf | grep -E "am(swap|add|and|or|xor|max|min)|ammax|ammin|f(add|sub|mul|div|madd|cmp|mov|cvt|sqrt)" \
	  && echo "CHECK FAILED: forbidden AM/FP instructions found" \
	  || echo "CHECK OK: no AM/FP instructions"

check: boot.elf
	$(READELF) -h boot.elf
	$(OBJDUMP) -d boot.elf | grep -E "am(swap|add|and|or|xor|max|min)|ammax|ammin|f(add|sub|mul|div|madd|cmp|mov|cvt|sqrt)" \
	  && echo "CHECK FAILED: forbidden AM/FP instructions found" \
	  || echo "CHECK OK: no AM/FP instructions"

clean:
	rm -f $(OBJS) demo_start.o demo_payload.o boot.elf boot.bin demo_payload.elf

.PHONY: all check clean
