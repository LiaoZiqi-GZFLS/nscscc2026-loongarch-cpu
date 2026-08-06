# sw/linux — T2026143250012561 LA32R + chiplab Linux 5.14 适配层

面向决赛「Linux+操作」里程碑：在本队 LA32R 核 + chiplab 平台上启动
Linux 5.14 + busybox 最小根文件系统（内含 `sh`、`ls` 等 applet）。

> 内核源码本体不进本仓库。本目录只含适配层：补丁、配置增量、构建脚本、
> 根文件系统模板与构建产物（`out/`）。完整复现执行 `./build.sh all` 即可。

## 0. 两个构建变体

| | **verilator-flow** | **board-16m** |
|---|---|---|
| 目标 | chiplab verilator 官方 linux 流程 | nscscc-team 最小 SoC 上板 |
| RAM 布局（DTS memory） | 物理 0 起 128MB | **16MB @ 0x1c000000** |
| 内核链接/加载 | 物理 0x300000（虚址 0xa0300000） | **物理 0x1c300000（虚址 0xbc300000）** |
| 内核配置 | la32_defconfig 原样 | la32_defconfig + `config/board-16m.fragment` 裁剪 |
| 额外补丁 | 0001/0002/0003/0005/0006 | 上述 + **0004（memory 节点）** |
| 镜像大小（vmlinux.bin） | ~13.3MB（verilator RAM 充裕） | 见 §5 预算，须 << 16MB |
| 产物目录 | `out/verilator-flow/` | `out/board-16m/` |

两变体共用：busybox initramfs（内嵌）、`boot/start.S` 引导 stub（变体无关）、
UART 100MHz 修正、105MHz 定时器修正、DMW 512MB 段修正。

## 1. 软件栈来源

| 组件 | 来源 | 版本 / 标识 |
|---|---|---|
| 内核 | https://gitee.com/loongson-edu/la32r-Linux （分支 la32r-new-world） | Linux 5.14.0-rc2 移植，commit `4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e` |
| busybox | https://busybox.net/downloads/busybox-1.36.1.tar.bz2 | 1.36.1，静态链接 |
| 交叉工具链 | loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0（gitee loongson-edu/la32r-toolchains v0.0.3） | gcc 8.3.0，ilp32s 软浮点，ELF32 |

## 2. 构建

```sh
export PATH=<工具链>/bin:$PATH     # loongarch32r-linux-gnusf-gcc 须在 PATH
./build.sh all                     # 两变体全量构建，产物在 out/
./build.sh verilator               # 只构建 verilator-flow
./build.sh board-16m               # 只构建 board-16m
```

host 依赖：`gcc make flex bison bc perl python3 gzip git curl`。

## 3. 相对上游的改动清单（patches/，按序 git apply）

| 补丁 | 内容 | 理由 |
|---|---|---|
| 0001 | `arch/loongarch/include/asm/time.h`：LS_SOC 恒定频率计时器 200MHz→**105MHz** | 上游硬编码龙芯实验箱 200MHz；本队核稳定计数器 105MHz，不改则时钟/延时约 2 倍失真。**决赛实际 CPU 时钟变化须同步改此值重编** |
| 0002 | `loongson32_ls.dts`：串口 `clock-frequency` 33MHz→**100MHz** | chiplab 16550 挂 sys_clk=100MHz（比赛规则 sys_clk 恒定，仅 cpu_clk 可调）；33MHz 会使内核 8250 重算除数（33M/16/115200≈18）后真板乱码。100MHz 下除数=54，与 bootloader（DLL=54）无缝衔接 |
| 0003 | **DMW 段长 256MB→512MB**：`addrspace.h` DMW_PABITS 28→29；`loongarchregs.h` CSR_DMW0/1_VSEG 0x8/0xa→0x4/0x5；`traps.c` TLBRENTRY 掩码 0x0fffffff→0x1fffffff；`tlbex-32.S` refill 页表地址掩码同上 | LA32R DMW 为 3bit VSEG/PSEG、512MB 段。上游按 256MB 假设会把 ≥0x10000000 的物理地址截断 bit28——16MB 最小 SoC DDR 在 0x1c000000（448MB），不改则 __pa/TLBRENTRY/refill 页表访问全部错位。对 RAM 在 0~128MB 的 verilator 流程语义不变 |
| 0004 | `loongson32_ls.dts`：memory 节点 0x0/128MB→**0x1c000000/16MB**（仅 board-16m 应用） | 最小 SoC DDR 窗口 |
| 0005 | `loongson32/setup.c`：`register_gop_device` 加 `#ifdef CONFIG_VT` 守卫 | 裁剪配置关 VT 后编译失败（上游缺守卫） |
| 0006 | `boot_param.h`：`screen_info` 改由 uapi 头引入 | 同上，VT=n 时 `struct screen_info` 不完整 |
| 0007 | `kernel/setup.c`：`screen_info` 无条件定义 | VT=n 时 env.c/efi earlycon 仍引用它，链接失败 |
| 0008 | **cache 几何修正**：`cache.c` probe_pcache 硬编码 `0xfe994cd3`(16B/256sets/2way)→`0xfe2914d3`(**64B/64sets/2way**，按内核自身解码公式)；`waybit` 赋值（原全树恒 0，blast 全清只覆盖 way 0）；`cacheflush.h` 补 `cache64_unroll32` 与 blast_*64 实例，`cache.c` 两处 `blast_dcache16()`→`blast_dcache64()` | 本核 ICache/DCache 各 64sets×64B×2way（8KB VIPT）。内核按错误 line/index 位宽做 index 类 cacop 维护 → 清不全/清错位置 |

配置增量：`config/chiplab-la32.fragment`（INITRAMFS_SOURCE 说明，两变体通用）、
`config/board-16m.fragment`（board-16m 裁剪：关 NET/VT/MODULES/CGROUPS/BPF/
多余文件系统与驱动等，保留 16550 串口、proc/sysfs/tmpfs、KALLSYMS）。

链接地址：board-16m 由 `make CONFIG_PHYSICAL_START=0xbc300000` 控制
（`arch/loongarch/Makefile` 的 `load-y` 覆盖 loongson32/Platform 的 0xa0300000）。

## 4. initramfs 方案

`CONFIG_INITRAMFS_SOURCE` 内嵌（单镜像，bootloader 只需加载一个内核镜像）。
`out/rootfs.cpio.gz` 同时产出，支持外挂 initrd 备选（命令行 `rd_start=/rd_size=`）。

## 5. board-16m 内存预算

16MB 窗口：`0x1c000000`(start.bin, 768B) + `0x1c300000`(内核) ~ `0x1d000000`。

- 未裁剪内核镜像 13.3MB+bss 0.5MB → 0x1c300000+13.85MB = **0x1D0D9000，超窗**，
  故 board-16m 必须裁剪（`config/board-16m.fragment`）。
- 裁剪后实际值见 `out/board-16m/README.txt`（目标 bin+bss ≤ 8MB，
  保留 ≥ 7MB 给页表/slab/页缓存/busybox 用户态）。
- 若未来镜像仍过大，备选：进一步关 KALLSYMS/PRINTK、外挂 initrd（内核镜像
  减 ~1.3MB）、或 SoC 侧扩 DDR 窗。

## 6. 启动协议（两变体通用，boot/start.S 实现）

1. CPU 复位 @`0x1c000000`（start.bin 位置）。
2. start.S 初始化 16550（除数=1 兜底打印）→ 写 DMW0=0xa0000011 /
   DMW1=0x80000001（0xa0000000 缓存 / 0x80000000 非缓存窗口，512MB 段均映到
   物理段 0，覆盖 0x0~0x1fffffff）→ CRMD 开 PG → 跳 kernel_entry（从 vmlinux
   ELF 符号表读取，mkimage.sh 自动提取）。
3. fw_arg：a0=2，a1=argv（内嵌于 start.bin，缓存窗口虚址 0xbc0000xx，
   指向物理 start.bin 内的 `"g"` 与命令行字符串），a2=全 0 bootparam 区。
   命令行默认 `console=ttyS0,115200 rdinit=/init loglevel=8`（mkimage.sh
   `CMDLINE` 可改）。**内存大小来自内嵌 DTS，不经 fw_arg。**
4. 上板加载：start.bin→0x1c000000，vmlinux.bin→其物理加载地址
   （verilator-flow: 0x300000；board-16m: 0x1c300000），JTAG-AXI/verilator
   rom.vlog 均可（`boot/mkimage.sh` 生成 rom.vlog，地址自动按变体计算）。

## 7. CPU 硬件前提（本内核 32 位路径实际依赖）

本内核 32 位走 `arch/loongarch/kernel/cpu-probe32.c`：**不读 CPUCFG/PRCFG/IOCSR**
（PRID 硬编码 0x4200，TLB 几何硬编码且仅影响 hugepage 阈值，TLB 失效走 invtlb
全清）。**RTL 侧补齐 CPUCFG/PRCFG/IOCSR 是面向主线/更新内核的保险，本 5.14
32 位内核不消费它们。** 真正依赖：

- **TLB**：4KB 页（`write_csr_pagesize(4K)` 写后读回校验，失败 panic）；
  ASID ≥ 8bit（硬编码 asid_mask=0xff）；invtlb；TLBR 异常进 DA 模式
  （refill handler/TLBRENTRY 用物理地址）
- **恒定频率计时器 + 定时器中断**，频率与补丁值（105MHz）一致
- **LL/SC 原子指令**（产物已验证 0 条 AM* 指令）
- **无 FPU**：全部按 ilp32s 软浮点编译
- **DMW**：3bit VSEG/PSEG、512MB 段（与补丁 0003 匹配）
- 串口 16550 @0x1fe001e0（时钟 100MHz）、中断按 DTS（cpuic + extioi）
- Cache：本核 I/D 各 64sets×64B×2way（8KB VIPT），已由补丁 0008 匹配
  （原内核硬编码 16B/256sets 与 waybit=0 的 bug 一并修复）

## 8. 产物验收

各变体目录含 README.txt 与 verification 记录；硬指标：vmlinux = ELF32
LoongArch；`objdump -d vmlinux` 全扫 AM* 原子指令 = 0；
`rootfs.cpio.gz` 解包含 `/bin/ls`、`/bin/sh`、`/dev/console`（39 项）。
