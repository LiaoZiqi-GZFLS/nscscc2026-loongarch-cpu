# sw/linux — T2026143250012561 LA32R + chiplab Linux 5.14 适配层

面向决赛「Linux+操作」里程碑：在本队 LA32R 核 + chiplab 平台上启动
Linux 5.14 + busybox 最小根文件系统（内含 `sh`、`ls` 等 applet）。

> 内核源码本体不进本仓库。本目录只含适配层：补丁、配置增量、构建脚本、
> 根文件系统模板与构建产物（`out/`）。完整复现执行 `./build.sh` 即可。

## 1. 软件栈来源

| 组件 | 来源 | 版本 / 标识 |
|---|---|---|
| 内核 | https://gitee.com/loongson-edu/la32r-Linux （分支 la32r-new-world） | Linux 5.14.0-rc2 移植，commit `4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e` |
| busybox | https://busybox.net/downloads/busybox-1.36.1.tar.bz2 | 1.36.1，静态链接 |
| 交叉工具链 | loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0（gitee loongson-edu/la32r-toolchains v0.0.3） | gcc 8.3.0，ilp32s 软浮点，ELF32 |

## 2. 构建

```sh
export PATH=<工具链>/bin:$PATH     # loongarch32r-linux-gnusf-gcc 须在 PATH
./build.sh                          # 全部自动完成，产物在 out/
```

host 依赖：`gcc make flex bison bc perl python3 gzip git`。
内核构建细节：`make ARCH=loongarch CROSS_COMPILE=loongarch32r-linux-gnusf- la32_defconfig`，
随后 `CONFIG_INITRAMFS_SOURCE` 指向 `mkrootfs.sh` 生成的清单文件再 `make -j`。

### 相对上游的改动清单

| 改动 | 位置 | 理由 |
|---|---|---|
| 恒定频率计时器 200MHz → **105MHz** | `patches/0001-ls-soc-const-freq-105MHz.patch`（`arch/loongarch/include/asm/time.h`） | 上游硬编码龙芯实验箱 200MHz；本队核稳定计数器 105MHz，不改则内核时钟/延时约 2 倍失真。**若决赛实际 CPU 时钟变化（perf_clock.json 10~200MHz），须同步改此值重编** |
| 内嵌 initramfs | `config/chiplab-la32.fragment`（`CONFIG_INITRAMFS_SOURCE`） | 单镜像启动，不依赖 bootloader 额外传 initrd 地址，最稳 |

### initramfs 方案选择

上游支持两种：① `CONFIG_INITRAMFS_SOURCE` 内嵌（编译期链入 vmlinux）；
② bootloader 经 fw_arg 命令行 `rd_start=/rd_size=` 外挂 initrd（chiplab 官方
例程走这条路，initrd 放在物理 0x0308c000）。
**本队选 ①**：少一个地址约定，bootloader 只需加载一个内核镜像；
`out/rootfs.cpio.gz` 同时生成，若日后要改外挂方案可直接用（命令行加
`rd_start=0x<虚址> rd_size=<大小>`）。

## 3. 启动协议（bootloader / 上板接口）

内核启动遵循 chiplab nscscc2026 `software/examples/linux` 例程约定
（`boot/start.S` 已按此实现，与官方版兼容）：

1. **复位**：CPU 复位向量 `0x1c000000`，此处放 `start.bin`（`boot/mkimage.sh` 生成）。
2. **内存映射**：start.S 配置 DMW0/1 —— 虚址 `0x80000000`（cached）/ `0xa0000000`
   （uncached）均直映物理 `0x0`，开 PG 后跳 `kernel_entry`（从 vmlinux ELF 符号表读取）。
3. **内核加载**：`vmlinux.bin` 按其链接虚址对应的物理地址加载
   （KSEG0：物理地址 = 虚址 − 0x80000000）。实际值见 `out/` 构建日志 /
   `readelf -S out/vmlinux` 的 `.text` 地址。chiplab verilator 流程中该地址为
   物理 `0x300000`（`rom.vlog` 已按此生成）。
4. **fw_arg 约定**（a0~a2）：
   - `a0 = 2`（argc）
   - `a1 = argv`：指针数组 + 字符串（`"g"`，命令行），uncached 虚址。
     命令行默认 `console=ttyS0,115200 rdinit=/init loglevel=8`（`boot/mkimage.sh`
     的 `CMDLINE` 变量可改）
   - `a2 = bootparam` 区：全 0 内存（内核按 `bootparamsinterface` 解析，全 0 即
     无扩展链表，与官方行为一致）
   - **内存大小不通过 fw_arg 传递**：本内核内存布局来自内嵌 DTS
     （`loongson32_ls.dts` 的 `memory { reg = <0x0 0x08000000> }`，即物理 0 起 128MB）
5. **串口**：16550 @ `0x1fe001e0`，115200 8N1。start.S 用除数=1 初始化；
   内核 8250 驱动随后按 DTS `clock-frequency=<33000000>` 重算除数（=18）。
   若上板后内核日志乱码而 start.S 横幅正常，说明实际 UART 时钟 ≠33MHz，
   需按实际时钟改 DTS `serial@0x1fe001e0` 的 `clock-frequency` 后重编。

### verilator 仿真

`boot/mkimage.sh` 生成的 `rom.vlog` 与 chiplab `sims/verilator/run_prog`
的 RAM 模型格式兼容（`@地址` + 每行一字节十六进制）：`start.bin` @ `0x1c000000`，
`vmlinux.bin` @ 内核物理加载地址。参照官方例程把它作为软件镜像运行即可。

## 4. CPU 硬件前提（本内核 32 位路径实际依赖，已与核设计对齐）

本内核 32 位走 `arch/loongarch/kernel/cpu-probe32.c`（**不读** CPUCFG/PRCFG/IOCSR，
PRID 硬编码 0x4200，TLB 几何硬编码 mtlb=64/stlb=8×256——该值仅影响 hugepage
阈值，TLB 失效走 invtlb 全清，不迭代项数）。真正依赖：

- **TLB**：支持 4KB 页（`write_csr_pagesize(4K)` 写后读回校验，失败直接 panic）；
  ASID ≥ 8bit（内核硬编码 asid_mask=0xff）；invtlb 指令
- **恒定频率计时器 + 定时器中断**（LLFTP 等价能力），频率须与补丁值（105MHz）一致
- **LL/SC 原子指令**（内核 cmpxchg/futex 走 LL/SC 路径；产物已验证 0 条 AM* 指令）
- **无 FPU**：内核/用户态均按软浮点编译（ilp32s）；defconfig 的 `CONFIG_CPU_HAS_FPU`
  仅影响 FPU 上下文代码路径，32 位 probe 不使能 FPU
- 串口 16550 @0x1fe001e0、中断线按 DTS（cpuic + extioi）
- Cache：内核硬编码 I/D 各 8KB、2 路、16B 行（`arch/loongarch/mm/cache.c`
  `config=0xfe994cd3`），CACOP 按此几何执行

> 注：侦察报告中「PRID=0x00144200 / PRCFG3 TLB 项数 / IOCSR 读 0 写忽略」是
> 64 位 `cpu-probe.c` 路径的要求；核里补齐 CPUCFG/PRCFG/IOCSR 对兼容性仍有价值
> （主线/更新内核会用），但本 5.14 32 位内核不读取它们。

## 5. 产物验收（`out/`）

- `vmlinux`：ELF32 LoongArch 内核（含内嵌 initramfs）
- `vmlinux.bin`：裸二进制（objcopy 段清单与 chiplab 官方一致）
- `start.bin` / `rom.vlog`：引导 stub / verilator 内存初始化文件
- `rootfs.cpio.gz`：独立 initrd（含 `/bin/busybox` 与 `sh/ls/...` 链接）
- `busybox`：静态 ELF32 LoongArch
- `kernel.config`、`initramfs_list.txt`：复现凭证

验收硬指标（另见 `out/verification.txt`）：vmlinux = ELF32 LoongArch，
entry `0xa0b84c70`，`.text` 虚址 `0xa0300000` → **物理加载地址 `0x300000`**；
`objdump -d vmlinux` 全扫 AM* 原子指令 = **0**（反汇编 234 万行）；
`rootfs.cpio.gz` 解包含 `/bin/ls`、`/bin/sh`、`/dev/console` 等 39 项。
镜像大小：`vmlinux.bin` 13,340,928 B，`rootfs.cpio.gz` 1,312,992 B（内嵌进内核），
`start.bin` 768 B。
