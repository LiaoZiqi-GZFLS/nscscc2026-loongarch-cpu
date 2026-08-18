# Linux 5.14.0-rc2 启动修复记录

## 目标与当前结论

目标是在 16 MB RAM 的 NSCSCC SoC 上启动 Linux 5.14.0-rc2，加载外置
initramfs，并通过 UART 进入 `/init` 和 BusyBox shell。

截至 2026-08-15，本地 Chiplab Verilator + NEMU Difftest 已稳定越过 Linux
早期初始化、首次定时器中断和首次真实 TLB refill。300 ms 仿真执行
77,216,713 条指令，无 Difftest mismatch。系统尚未到达 `Freeing initrd` 或
`Run /init`；当前继续排查 8250 UART 初始化后的发送等待。

## 固定配置

- 内核版本：Linux 5.14.0-rc2，源码提交
  `4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e`
- RAM：`0x1c000000..0x1d000000`，共 16 MB
- 启动桩：物理地址 `0x1c000000`
- 内核：物理地址 `0x1c300000`，链接地址 `0xbc300000`
- 当前内核入口：`0xbc593fa0`
- initrd：物理地址 `0x1ca00000`，cached 地址 `0xbca00000`
- initrd 大小：1,312,992 字节
- DMW0：`0xa0000011`，cached 直接映射窗口
- DMW1：`0x80000001`，启动参数使用其 uncached 别名
- `argv`：`0x9c000140`
- `bootparam`：`0x9c000200`

## CPU RTL 修复

正式源文件为
`src/vivado_cannot/src/pipeline/privilege/ExceptionHandlerPlugin.scala`。

1. 普通异常入口按 LoongArch 向量布局计算：

   ```text
   target = EENTRY + (ECODE - 32) * 0x200
   ```

   中断仍进入 `EENTRY`，TLB refill 直接进入 `TLBRENTRY`，不叠加普通异常
   偏移。

2. 新增 `tlbrActive` 状态。TLBR 进入时强制 `DA=1, PG=0`，对应的 `ERTN`
   才恢复 `DA=0, PG=1`，避免用已被其他异常覆盖的 `ESTAT.ECODE` 判断。

3. ECFG bit 10 是保留位，读零且写入忽略；有效 LIE 位与参考模型保持
   一致。

此前还修复了 MMU 重复 TLB 命中优先级、取指和数据流水级翻译刷新。这些
修改已经在当前分支的前序提交中。

## Linux 镜像与启动修复

### 启动参数和 DMW

`sw/linux/boot/start.S` 使用与内核一致的 cached DMW0，避免内核切换缓存
属性后读到旧的启动参数。`argv` 和 BPI bootparam 通过 DMW1 uncached 别名
传递；改写 DMW1 前先经 DMW0 trampoline 跳转，防止当前取指地址失效。

### 外置 initramfs

`sw/linux/boot/mkimage.sh` 和 `sw/linux/build.sh` 现在会：

- 从符号表提取 `kernel_entry`，stripped ELF 则回退到 ELF header entry；
- 将 rootfs 放到 `0x1ca00000` 并自动生成准确的 `rd_start`/`rd_size`；
- 把 initrd 合并到 Verilator `rom.vlog`；
- 输出 ELF LOAD segment 的 FileSiz/MemSiz，供 JTAG loader 清理 `.bss`；
- 在构建结束时运行 16 MB 内存布局检查。

`load_linux_hw.tcl` 加载 start、kernel 和 initrd，并清理 kernel 未出现在
`vmlinux.bin` 中的 NOBITS 尾部，避免重复上板时继承旧 `.bss` 数据。

### 动态代码 cache 一致性

`sw/linux/patches/0011-flush-generated-code-caches.patch` 将
`local_flush_icache_range()` 修正为：

```text
blast_dcache_range -> dbar 0 -> blast_icache_range -> ibar 0
```

Linux 复制动态异常向量后，CPU 因此能取到新指令，不再执行 cache 中的零
指令。

## Chiplab Difftest 修复

验证工作树：`/tmp/opencode/chiplab-nscscc2026`。

- 异常指令已经包含在本批 commit 时，不再额外执行一次 NEMU，修复同步
  异常 double-step。
- 硬中断时同步 DUT 完整架构状态、ESTAT 和 EENTRY PC，并用 guided exec
  重定位参考模型 PC。
- 硬中断全状态同步时清空 NEMU store commit queue，避免中断前后的 store
  事件错位。
- `csrrd ESTAT` 同步实时 `dut.csr.estat`；CSR 写类指令继续使用提交数据。

## NEMU 参考模型修复

验证工作树：`/tmp/opencode/la32r-nemu/NEMU`。

- 普通异常入口采用 `(ECODE - 32) * 0x200`，TLBR 直接进入
  `TLBRENTRY`。
- guided exec 同时更新 `cpu.pc` 和 performance tcache 状态。
- 导出 `difftest_store_queue_clear()`，支持硬中断全状态同步。
- shared library 构建不再依赖 readline headers。
- 参考 TLB 项数改为与 DUT 一致的 16 项。
- DA 模式不是虚实地址恒等映射。取指、读、写和 MMU translation 均使用：

  ```text
  paddr = vaddr & 0x1fffffff
  ```

  例如 `0xbc307ec8` 必须访问物理地址 `0x1c307ec8`。

## UART 当前问题

Linux 8250 探测会把 `0xa5`、`0x5a` 写到标准 Scratch Register 7。Chiplab
UART IP 原先把地址 7复用为 `mode_reg`，`0xa5` 会把 UART 切换到 USART
接收模式，导致 `LSR.THRE` 永久为零。验证环境已增加独立 `scratch_reg`，
非 DLAB 访问地址 7不再改变 UART 工作模式，并已完成 Verilator 重建。

修复后的 220 ms 仿真执行 37,216,713 条指令且无 Difftest mismatch，但结束
时仍位于 `restore_partial` 的 UART `LSR[5]` 轮询。UART 文件尚未越过
`add_uevent_var: buffer size too small` warning，因此还需观察 `tf_count`、
`tstate`、`block_cnt`、`current_finish` 和 `LSR[5]`，确认是否存在第二个
发送状态问题。

该 warning 不是 panic，内核在 warning 后仍持续执行。当前不能宣称已经
进入 initramfs 或 shell。

## 验证记录

| 仿真 | 指令数 | 结果 |
| --- | ---: | --- |
| 175 ms，中断/store queue 修复 | 23,416,083 | 无 mismatch，越过首次定时器中断 |
| 205 ms，DA 直接映射修复 | 29,716,713 | 无 mismatch，越过首次真实 TLB refill |
| 300 ms，DA 读写修复 | 77,216,713 | 无 mismatch，UART THRE 轮询 |
| 220 ms，UART scratch 修复 | 37,216,713 | 无 mismatch，仍需检查发送状态 |

关键验证日志位于 Chiplab 工作树的：

```text
sims/verilator/run_prog/board_cachefix/run205_directio.log
sims/verilator/run_prog/board_cachefix/run300_directio.log
sims/verilator/run_prog/board_cachefix/run220_uart_scr.log
sims/verilator/run_prog/board_cachefix/uart_output.txt.real
```

## 后续步骤

1. 观察 UART 内部发送状态，解决 `LSR.THRE` 未恢复问题。
2. 继续 Verilator 仿真到 `Freeing initrd`、`Run /init` 和 BusyBox shell。
3. 将 UART 修复同步到正式 SoC IP 构建来源。
4. 重新构建正式 `board-16m` 镜像和 FPGA bitstream。
5. 在 100 MHz FPGA 上验证 reset、JTAG 加载、UART 和 BusyBox shell。

当前所有长时间验证均为本地仿真，没有占用 FPGA、JTAG 或
`/dev/ttyUSB2`。
