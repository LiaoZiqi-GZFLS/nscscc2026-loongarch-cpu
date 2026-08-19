# FPGA Hardware Test Summary

## Hardware

- FPGA: `xc7a200t_0`
- JTAG target: `Digilent/210357A7D00EA`
- JTAG USB: `0403:6010`
- UART USB: `0403:6001`, 115200 8N1
- Bitstream: `bit/sys_test/bit/sys_soc_top_100mhz.bit`

## Verified

- Bitstream programming completed successfully.
- JTAG AXI core `hw_axi_1` was detected after `refresh_hw_device`.
- DDR writes and readback checks succeeded.
- uCore reached its shell and passed the early memory-management checks.
- Linux reaches `Run /init as init process`, detects the CPU/caches/16 MiB DDR,
  initializes SLUB, timers, devtmpfs, and the 8250 console.

## Linux Image Layout

- `start.bin`: `0x1c000000`
- `vmlinux.bin`: `0x1c300000`
- `rootfs.cpio.gz`: `0x1c900000`, 1,312,992 bytes

Last successful readback values:

```text
VERIFY_START=143fc00d
VERIFY_KERNEL=1c0060c7
VERIFY_INITRD=00088b1f
```

## Current Fixes

The Linux startup stub now provides:

- Real-board UART divisor: DLL `0x36`, DL3 `0x40`
- Official chiplab DMW values
- Command line with `rd_start=0x1c900000 rd_size=1312992`
- A valid `BPI01000` structure and checksummed MEM extension node

Hardware testing on 2026-08-07 found and fixed two early boot errors:

- The upstream `memblock_reserve(PHYS_OFFSET, 2MB)` reserved physical address
  zero, outside this board's RAM. The loader then reused the start stub and
  exception-vector area. Patch 0010 now reserves `0x1c000000-0x1c2fffff`.
- Early parsing reduced `boot_command_line` to `earlycon`. Patch 0009 preserves
  the complete architecture command line, including `console=ttyS0` and
  `rdinit=/init`.
- JTAG loading now clears the ELF `MemSiz-FileSiz` tail so `.bss` cannot retain
  state across repeated boots. One-click startup also reprograms the FPGA by
  default to cold-reset CPU/cache state.

Last verified Linux milestone:

```text
Memory: 7040K/16384K available
1fe001e0.serial: ttyS0 ... is a 16550A
Run /init as init process
```

The remaining blocker is after successful `kernel_execve("/init")`: no first
userspace output appears. This narrows the next investigation to the LA32 user
return/TLB-refill path rather than initramfs discovery or the BusyBox image.
