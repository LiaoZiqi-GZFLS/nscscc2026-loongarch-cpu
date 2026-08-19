# Linux FPGA Bring-up State - 2026-08-19

## Branch Archive

- Source branch: `t26-final`
- Archive branch: `archive/t26-linux-bringup-20260819`
- Environment-specific WSL2/USB setup is documented outside Git under
  `~/docs/WSL2-Vivado-Digilent-JTAG-连接指南.md`.

## Reproducible Hardware Configuration

- FPGA: `xc7a200t_0`
- JTAG target: `Digilent/210357A7D00EA`
- hw_server: `localhost:3122`
- CPU UART: `/dev/ttyUSB2`, 115200 8N1
- start stub: physical `0x1c000000`
- kernel: physical `0x1c300000`, virtual `0xbc300000`
- initramfs: physical `0x1ca00000`, virtual `0xbca00000`
- kernel entry: `0xbc593b50`

## Verified Changes

- Linux DMW setup now follows the kernel convention:
  - DMW0 `0x80000001`: uncached window.
  - DMW1 `0xa0000011`: cached window.
- The boot stub transitions through the old DMW mapping before replacing both
  windows and jumping to the kernel.
- Hardware Tcl scripts accept `HW_SERVER_URL`, allowing use of port 3122.
- Linux image loading holds CPU reset, writes start/kernel/initramfs, clears the
  ELF NOBITS tail, and verifies start/kernel words before release.
- Latest SpinalHDL RTL was regenerated, synthesized, implemented, programmed,
  and tested on FPGA. Vivado completed bitstream generation with 0 errors.

## Current Failure

Both FPGA and same-image Verilator execution reach:

```text
T26 ARCH: paging_init done
T26 ARCH: boot_cpu_trap_init done
T26 INIT: setup_arch done
T26 INIT: setup_boot_config done
```

Neither reaches `setup_command_line done`. Changing `argc` from 2 to 1 did not
change the stop point, ruling out `argv[1]` string access as the primary cause.

The 100-million-time-unit same-image Verilator run then loops around:

```text
bc201a00
bc201a04
```

with `except=1`, indicating an exception/refill loop after boot config setup.
The relevant log is outside the repository at:

```text
/tmp/opencode/chiplab-nscscc2026/sims/verilator/run_prog/board_nop_linux/run311_sameimage_100m.log
```

## Next RTL Diagnosis

Capture the first failing access rather than adding broad pipeline logs:

- exception PC and ECODE/ESUBCODE;
- BADV;
- CRMD and PRMD;
- ERA and TLBRENTRY;
- TLBEHI, TLBELO0, TLBELO1, PGD, PGDL, and PGDH;
- last instruction/data AXI address and handshake state.

Use these values to distinguish:

- bad DMW physical segment generation;
- refill handler instruction fetch failure;
- page-table load failure;
- stale CSR state at `tlbfill` or `ertn`;
- nested exception handling that overwrites the original refill state.

Do not continue modifying UART, `argc`, `argv`, or command-line strings unless
new evidence points back to those paths.
