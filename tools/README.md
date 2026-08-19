# Board Tools

## One-click Linux startup

The board image is a Linux initramfs: files under `/` are unpacked into RAM and
`/tmp` and `/run` are mounted as tmpfs. The board-16m layout reserves 4 MiB
after the images for page tables, slab, and user processes.

```sh
./tools/start_linux.sh --port /dev/ttyUSB0
```

By default the script reprograms the FPGA before loading Linux. This provides
a cold reset for the CPU, caches, and DDR-facing logic, which is required for
repeatable boots. Use `--no-program` only when the board has already been
reprogrammed separately.

Use `--no-console` when only loading the image is wanted. Override the serial
device with `UART_PORT=/dev/ttyUSB1`; the default is `/dev/ttyUSB0` at 115200 8N1. The script
expects Vivado's `hw_server` at `localhost:3121`, as do the existing TCL files.

The memory check can be run independently:

```sh
./sw/linux/check_memory.sh board-16m
```

Set `RAM_SIZE`, `RAM_BASE`, `KERNEL_ADDR`, `ROOTFS`, or `RESERVE` to validate
another board layout. The estimate includes ELF `.bss` and the unpacked
initramfs and fails before JTAG writes if there is insufficient runtime RAM.

## UART interaction

The console uses Python's Linux `termios` interface, has no third-party
dependencies, restores the terminal on exit, and reports boot milestones and
the first boot stall on stderr. Received bytes are appended to a durable log:

```sh
python3 tools/uart_console.py /dev/ttyUSB0 --baud 115200 --log logs/linux-uart.log
```

Press `Ctrl-]` to exit. Linux commands can then be entered directly, for
example `ls /`, `free`, and `mount`.

The one-click startup command uses `logs/linux-uart-live.log` by default and
reports a boot timeout after 45 seconds without terminating the console:

```sh
./tools/start_linux.sh --port /dev/ttyUSB0 --log logs/linux-uart-live.log
```

Use `--boot-timeout 0` to disable the warning. A timeout after `Run /init as
init process` points to the known remaining userspace return/TLB-refill issue;
it does not indicate a failed image load.
