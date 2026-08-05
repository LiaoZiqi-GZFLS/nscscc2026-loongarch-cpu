# Makefile - NSCSCC2026 mini bootloader (LA32R + chiplab)
#
# Toolchain: loongson-gnu-toolchain-8.3 (la32r, ilp32s soft-float)
#   /home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf-gcc
#
# Outputs: boot.elf (for objdump/debug) and boot.bin (for JTAG-AXI download)

CROSS_COMPILE ?= /home/kimi/tc/la32r/bin/loongarch32r-linux-gnusf-
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

check: boot.elf
	$(READELF) -h boot.elf
	$(OBJDUMP) -d boot.elf | grep -E "am(swap|add|and|or|xor|max|min)|ammax|ammin|f(add|sub|mul|div|madd|cmp|mov|cvt|sqrt)" \
	  && echo "CHECK FAILED: forbidden AM/FP instructions found" \
	  || echo "CHECK OK: no AM/FP instructions"

clean:
	rm -f $(OBJS) boot.elf boot.bin

.PHONY: all check clean
