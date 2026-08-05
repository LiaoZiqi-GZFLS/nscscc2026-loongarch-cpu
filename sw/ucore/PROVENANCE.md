# PROVENANCE — sw/ucore

## Upstream

- Repository: https://github.com/cyyself/ucore-loongarch32
- Branch: `master`
- Commit: `843f8b7c76a8c10a7e268dc7a80af5b05ef1bcc6` (2022-11-02, "don't check large rb_tree")
- License: upstream ships **no LICENSE file**; it is a port of THU ucore
  (ucore-thumips). We preserve all original copyright notices in sources.
- Upstream itself was verified by its author to run on chiplab's LA32 soft core.

## Toolchain

- `loongarch32r-linux-gnusf-gcc` 8.3.0 (LoongArch GNU toolchain LA32 v2.0,
  gitee loongson-edu/la32r-toolchains v0.0.3), ELF32, ilp32s soft-float.

## Team modifications (all marked `// 2026-final: chiplab/nscscc adaptation`)

| File | Change | Reason |
|---|---|---|
| `tools/kernel.ld` | link base `0xa0000000` -> `0xbc000000` | chiplab nscscc-team SoC maps DDR3 at physical 0x1c000000 (16MB window), not 0; 0xbc000000 = DMWIN0 window base 0xa0000000 + 0x1c000000 |
| `kern/mm/memlayout.h` | add `PHYSMEM_BASE 0x1c000000`, `KMEMBASE = KERNBASE+PHYSMEM_BASE`; `KMEMSIZE` 32M->16M; `KERNTOP = KMEMBASE+KMEMSIZE` | match chiplab DDR base/size |
| `kern/mm/mmu.h` | `PPN(la)` subtracts `KMEMBASE` instead of `KERNBASE` | managed pages start at DDR window, not window base |
| `kern/mm/pmm.h` | `page2pa()` bases at `KMEMBASE`; `PADDR` validity floor `KMEMBASE` | same |
| `kern/mm/default_pmm.c` | asserts use `KMEMBASE` | consistency |
| `kern/init/entry.S` | dual-mode entry trampoline: program DMWIN0 cached window + DMWIN1 *identity* window, `csrxchg` CRMD PG=1/DA=0, jump to linked VA, then reprogram DMWIN1 to uncached IO window | tolerates both PMON-style handoff (entered at linked VA, PG on) and bare-metal handoff (entered at PA 0x1c000000 in DA mode). Identity window lives in DMW1 because our core implements only DMW0/DMW1 (src/vivado_cannot CSRPlugin.scala); trick mirrors chiplab software/examples/linux/start.S |
| `kern/driver/clock.c` | stable-counter period 200MHz -> 105MHz (100Hz = 1,050,000 counts) | our LA32R core's constant-frequency counter runs at the 105MHz CPU clock |
| `kern/driver/clock.c` | poll `serial_int_handler()` from the timer interrupt under LAB8 | nscscc-team SoC ties CPU `intrpt[7:0]` to 8'd0 (soc_top.v) — the 16550 RX interrupt line can never fire; without polling the shell would block forever in `dev_stdin_read()` |
| `kern/driver/console.c` | **rev2**: UART init = DLAB -> DLL/DLM -> DL3 (frac, at reg offset 2 while DLAB=1) -> 8N1 -> FCR=0x47; defaults DLL=0x36, DL3=0x40; `-DUCORE_VERILATOR_UART` keeps divisor=1 | real-board baud: URT IP is a 24-bit fractional divider `baud=PCLK/16/dl` clocked by sys_clk=100MHz (fixed by contest rules); divisor=1 only works in verilator (its UART model ignores timing). Values match sw/boot |
| `kern/include/loongarch.h` | **rev2**: `COM1_BAUD_DLL/DLM/DL3` derived from `UART_PCLK` (default 100MHz, overridable via `-DUART_PCLK=`) and `UART_BAUD` (115200); `CACHELINE_SIZE` 16 -> 64 | 100MHz/115200 -> dl=54.2539 -> DLL=54(0x36), DL3=64(0x40); our NOP core has 64-byte I/D cache lines (MyCPUConfig.scala), fence_i() CACOP stride must match |
| `kern/include/asm/loongisa_csr.h` | `__builtin_loongarch_csrrd/csrwr/csrxchg` -> `_w` variants | the 8.3 gnusf gcc only provides the `_w`-suffixed builtins; unsuffixed names silently became function calls and failed the link |
| `build.sh`, `PROVENANCE.md`, `out/` | new | reproducible build + ready-to-boot artifacts |

## Boot topology (two supported modes)

The kernel ELF entry point is **0xbc000000** (virtual, cached DMWIN0 window);
the single LOAD segment corresponds to physical **0x1c000000** (chiplab DDR
base). `entry.S` accepts both handoffs:

1. **Bootloader-copy mode (team default).** Team bootloader fetches
   `out/ucore.bin` (e.g. from staging area 0x1c400000), copies it to physical
   0x1c000000, and jumps to physical 0x1c000000 in DA mode. The entry
   trampoline arms an identity DMW window, flips CRMD to PG mode itself, and
   re-enters at the linked VA 0xbc000000.
2. **PMON-style mode.** A PMON-like monitor that has already configured
   DMWIN0/DMWIN1 and enabled PG loads the ELF at its virtual address and
   jumps to entry VA 0xbc000000. The trampoline is then a no-op mode-wise
   (csrxchg is idempotent) and reprograms the DMWs to ucore's own values.

In both cases: no AM* atomic instructions are required (0 in image, verified
in build.sh), no FPU instructions (0 in image), TLB refill uses `tlbfill`,
user pages are global 4KiB pages, timer interrupt is internal (ESTAT IS[11]).
