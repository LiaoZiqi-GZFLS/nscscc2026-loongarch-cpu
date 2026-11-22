# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

NSCSCC 2026 (龙芯杯) team T2026143250012561 submission repo: a LA32R (LoongArch 32-bit reduced) **out-of-order CPU written in SpinalHDL**, plus the chiplab-adapted software stack (bootloader → ucore → Linux) for the board system-test milestone.

The parent workspace CLAUDE.md (`../CLAUDE.md`) covers competition context, Vivado non-project flows, XDC templates, ILA debugging, and SpinalHDL coding rules. This file covers what is specific to this repo.

## Layout

- `src/vivado_cannot/` — **The RTL source of truth.** SpinalHDL 1.8.1 project (NOP-Core baseline). Edit here, regenerate Verilog, then copy to `src/mycpu/`.
- `src/mycpu/` — What the CI/Vivado actually synthesizes: generated `mycpu_top.v` (~123k lines, **do not hand-edit**), hand-written `core_top.v` wrapper, `xilinx_ip/multiplier/`.
- `src/perf_clock.json` — `cpu_clk_mhz: 105`. CI reads this to configure the Clock Wizard; sys_clk is fixed at 100 MHz by the platform.
- `sw/boot/` — Mini bootloader (ELF loader, fw_arg protocol) linked at reset address `0x1c000000`.
- `sw/ucore/` — ucore-loongarch32 port (upstream `cyyself/ucore-loongarch32`) adapted for this core + chiplab nscscc SoC; initrd with `sh`/`ls`/`cat`, UART file manager.
- `sw/linux/` — **Adaptation layer only** (patches, config, build scripts, artifacts). Kernel/busybox source is cloned by `build.sh`, not stored here.
- `bit/` — CI-produced bitstreams (func/perf/sys_test). `bit/sys_test/` holds at most one bit + its `bin/` + `doc/`.
- `show/` — Finals exhibition material (must match `src/`).
- `logs/` — Board test logs (`ucore-board-<timestamp>/` dirs, plus investigation notes like `linux-boot-investigation.md`).
- `*.tcl` at repo root — Manual JTAG-AXI board scripts (see below).

## Key Memory Map & Parameters (memorize)

| Item | Value |
|---|---|
| DDR window / CPU reset fetch | `0x1c000000`, 16 MB (chiplab nscscc-team minimal SoC) |
| Next-stage image staging area | `0x1c400000` (bootloader copies ELF from here) |
| fw_arg block (reserved) | `0x1cff0000`, top 64 KB of DDR |
| UART16550 | `0x1fe001e0`, PCLK = sys_clk = 100 MHz, 115200 = DLL `0x36` + DL3 `0x40` |
| CONFREG (7-seg / timer) | `0x1faf0000` (+`0xe000` for timer), JTAG poll addr `0x1faff050` |
| Stable counter | 105 MHz = CPU clock (timer interrupt period 1,050,000 = 100 Hz) |
| ucore link/entry | virt `0xbc000000` = phys `0x1c000000` (DMWIN0) |
| Linux board-16m | phys `0x1c300000` (virt `0xbc300000`); verilator-flow: phys `0x300000`, RAM 0-based 128 MB |
| CPU caches | I/D each 64 sets × 64 B × 2-way (8 KB VIPT); Linux patch 0008 must match this |
| TLB | 16-entry fully associative, 4 KB pages, ASID 8-bit; DMW 512 MB segments (3-bit VSEG/PSEG) |
| ISA subset | No `AM*` atomics, no FPU (all software ilp32s soft-float); CPUCFG/PRCFG1-3/IOCSR implemented (see `src/vivado_cannot/LINUX_SUPPORT.md`) |

## Build Commands

### RTL: SpinalHDL → Verilog (the only way `src/mycpu/mycpu_top.v` changes)

```bash
cd src/vivado_cannot
sbt "runMain NOP.Main"          # requires JDK 11+/17 (17 needs --add-opens flags, see COMPILE.md)
# or: java --add-opens java.base/java.lang=ALL-UNNAMED ... -jar sbt-launch.jar "runMain NOP.Main"
```

Produces `src/vivado_cannot/build/mycpu_top.v` (top module `mycpu_top`, entry `NOP.Main`). Copy it over `src/mycpu/mycpu_top.v` after verifying the diff is only the expected change (SpinalHDL signal-name line-number suffixes make naive diffs noisy — see the multi-set diff method in `LINUX_SUPPORT.md`). `core_top.v` is a hand-written wrapper and is not regenerated. Full reproducibility notes: `src/vivado_cannot/COMPILE.md`.

The Vivado MCP tools in this environment (`mcp__vivado__*`) can run synthesis/implementation and report timing/usage without driving Vivado by hand.

### Software

Toolchain: `loongarch32r-linux-gnusf-gcc` (gcc 8.3, ilp32s soft-float). `build.sh` scripts auto-detect common install locations; override with `TC=/path/to/toolchain`.

```bash
# ucore (artifacts: out/ucore.elf, ucore.bin, ucore.elf.stripped; ON_FPGA=y small app set)
cd sw/ucore && ./build.sh
# dev loop in QEMU (no FPGA): make qemu | make debug + make gdb (port 1234)

# bootloader (artifacts: boot.elf, boot.bin; make check verifies ELF32/entry/no-AM/FP)
cd sw/boot && make && make check

# Linux (both variants or one; needs network for kernel/busybox clone)
cd sw/linux && ./build.sh all          # or: verilator | board-16m
./check_memory.sh board-16m            # board-16m must stay << 16 MB window
```

`sw/linux/build.sh` env: `CROSS_COMPILE`, `KERNEL_URL`, `KERNEL_COMMIT`, `BUSYBOX_URL`, `CMDLINE`, `JOBS`. `sw/linux/boot/mkimage.sh <vmlinux> <outdir>` produces `vmlinux.bin`/`start.bin`/`rom.vlog` (rom.vlog initializes verilator RAM at variant-appropriate addresses).

### On-Board Tests (WSL/Linux host with Vivado + hw_server; board JTAG is FTDI `0403:6010`, standalone UART `0403:6001`)

Setup (USBIP forwarding, cable driver, `/dev/bus/usb`/`/dev/ttyUSB*` perms, `hw_server` on port 3122) is documented step-by-step in root `Readme.md` — follow it; device numbers change after every re-attach.

```bash
# Chiplab functional acceptance (programs bit/func_test/func_soc_top.bit, polls CONFREG)
HW_SERVER_URL=localhost:3122 FUNC_TIMEOUT=120 sh ./chiplab_func_board.sh

# ucore cold-boot stability: programs bit, JTAG-loads ucore.bin @0x1c000000, captures UART,
# requires "check_boot_pgdir() succeeded" + "user sh is running"
cd sw/ucore && HW_SERVER_URL=localhost:3122 UART=/dev/ttyUSB2 PROGRAM_BIT=each ROUNDS=1 BOOT_TIMEOUT=45 sh ./board_stability.sh
# Quick variants: PROGRAM_BIT=once (single program, N rounds) | PROGRAM_BIT=0 (skip programming, debug current FPGA)

# Interactive shell after a passing boot check
cd sw/ucore && sh ./uart_shell.sh     # needs picocom; UART=... HW_SERVER_URL=... PROGRAM_BIT=... overridable

# UART file transfer (host <-> ucore initrd FS; exit picocom first, only one reader per tty)
cd sw/ucore && python3 tools/ucore_uart.py --port /dev/ttyUSB2 put ./f.bin /f.bin
python3 tools/ucore_uart.py --port /dev/ttyUSB2 get /f.bin ./f.dl.bin && cmp ./f.bin ./f.dl.bin

# Linux on board (after building board-16m variant)
cd sw/linux && ../../tools/start_linux.sh --port /dev/ttyUSB1
```

Root-level manual TCL scripts (`HW_SERVER_URL` env-selectable; **contain hardcoded WSL paths — edit before use**):
`t26_program_hw.tcl` (program bit), `program_current_hw.tcl`, `load_ucore_hw.tcl` / `load_linux_hw.tcl` (JTAG-AXI write image + release CPU: reset reg `0x80000000`, release reg `0x40000000`), `probe_hw_axi.tcl` (list hw_axi objects), `pulse_cpu_hw.tcl`, `reset_system_hw.tcl` (VIO probes).

## CPU Architecture (big picture)

SpinalHDL plugin-based out-of-order LA32R core (`NOP.Main` → `MyCPU` → `mycpu_top`). Parameters in `src/vivado_cannot/src/MyCPUConfig.scala`; instruction encodings/CSR addresses in `src/vivado_cannot/src/constants/LoongArch.scala`.

Pipeline packages under `src/vivado_cannot/src/pipeline/`:

- `fetch/` — PC, fetch pipeline, branch prediction (global-history BTB + return address stack), I-Cache, instruction address translation.
- `decode/` — 3 parallel decoders (`DecoderArrayPlugin`), rename (`RenamePlugin`), physical-register-file model. **New instructions are added here** (`DecoderArrayPlugin.scala` + `constants/`), optionally `exe/ALU.scala` for execution.
- `exe/` — issue queues (int, mul/div), ALU/BRU/execute pipeline.
- `mem/` — address generation, D-Cache, store buffer, mem issue queue, uncached access path (I/O).
- `privilege/` — CSR, MMU (DMW0/1 + 16-entry TLB), exception/interrupt/wait handlers.
- `core/` — ROB (`ReorderBufferModel`), commit, speculative wakeup, bypass network, physical regfile, 64-bit timer; `builder/` is the generic pipeline framework (Pipeline/Stage/Plugin).

Top-level interfaces (`MyCPU.scala`): AXI4 master (to chiplab SoC crossbar), debug interfaces for chiplab (`break_point`, `ws_valid`/`rf_rdata`, `Dretire*`) and difftest (`DifftestBundle`). Perf/difftest use the `Dretire*` commit-bus signals — keep them intact when changing commit logic.

## Boot Topology

Two acceptance chains (details: `sw/RUNBOOK.md`, `sw/boot/README.md`):

- **Chain A (ucore, 10 pts):** bootloader @`0x1c000000` loads ELF from staging `0x1c400000` → jumps to ucore phys entry `0x1c000000`; ucore `entry.S` trampoline switches DA→PG itself (also works when ucore is loaded directly PMON-style).
- **Chain B (Linux, 15/20 pts):** bootloader or `start.bin` @`0x1c000000` sets DMW0=`0xa0000011`, DMW1=`0x80000001`, CRMD PG=1, then jumps `kernel_entry` with fw_arg (a0=2, a1=argv `console=ttyS0,115200 rdinit=/init loglevel=8`, a2=BPI block @`0x1cff0000`). Kernel has embedded DTS (memory node must be `0x1c000000`/16 MB — patch 0004) and embedded initramfs (busybox `/bin/sh`, `/bin/ls`).

`sw/linux/README.md` documents all 10 kernel patches (105 MHz timer, 100 MHz UART, DMW 512 MB segments, DTS memory, VT guards, cache geometry 0008, …) — any RTL change to timer frequency, cache geometry, or DMW segment size **must** be mirrored in these patches and in the sw assumptions above, or board behavior will silently break.

## Working Conventions & Gotchas

- **Never edit `src/mycpu/mycpu_top.v` directly** — changes disappear on regeneration; always edit SpinalHDL and regenerate. `core_top.v` is hand-written and safe to edit.
- **Branch workflow**: never push to `master`; feature branches only (main integration branch: `t26-final`). `.gitlab-ci.yml` and the Readme's required file layout (score.xlsx, design.pdf, `bit/`, `src/mycpu/xilinx_ip/`) are CI contracts — don't restructure them.
- **Timer frequency is baked into three software places** (ucore `clock.c`, bootloader `UART_PCLK`, Linux patches 0001/0002). If `cpu_clk_mhz` in `src/perf_clock.json` changes, all three must be rebuilt to match.
- Board test scripts are written for WSL with absolute paths (`/home/cjy/...`, `/mnt/wslg/...`, `/mnt/d/project/...`). Expect to adjust `TC`, `FUNC_BIN`, `FUNC_LTX`, and TCL image paths per machine.
- Known test-suite quirks are already adjudicated (see `LINUX_SUPPORT.md` §2026-08-06): PRELD decoded as nop (spec-compliant), CACOP stays privileged (lab19 n52 is a NEMU quirk, not a CPU bug), n7 ECFG mismatch is a reference-model quirk — don't "fix" these.
- Local functional regression assets (verilator func tests, difftest probes) live outside this repo at `/mnt/agents/output/work/func_regress/`; repo docs reference them.
