board-16m 变体（nscscc-team 最小 SoC 上板：16MB DDR @ 0x1c000000）
====================================================================
布局: RAM 物理 0x1c000000 起 16MB（0004 补丁改内嵌 DTS memory 节点）
内核: 链接/加载 物理 0x1c300000（虚址 0xbc300000 缓存窗口，
      make CONFIG_PHYSICAL_START=0xbc300000），kernel_entry 0xbc593b40
配置: la32_defconfig + config/board-16m.fragment（关 NET/VT/MODULES/CGROUPS/
      BPF/多余文件系统与驱动，保留 16550 串口、proc/sysfs/tmpfs、KALLSYMS）
关键前提: DMW 512MB 段（补丁 0003）——否则 0x1c000000 以上物理地址被
      256MB 掩码截断；TLBR 走 DA 模式物理地址（traps.c/tlbex-32.S 已同步）
命令行: console=ttyS0,115200 rdinit=/init loglevel=8（UART 100MHz，除数 54）

内存预算（16MB 窗 0x1c000000~0x1d000000）:
  0x1c000000  start.bin    768 B
  0x1c300000  vmlinux.bin  5,721,328 B (5.46MB)
  bss         0x7111c (463KB) -> 内核镜像末端 = 0x1c8f111c
  剩余可用 RAM ≈ 7.0MB（页表/slab/页缓存/busybox 用户态）
  注：0x1c000300~0x1c300000 的约 3MB 间隙亦在 memblock 内存内可被内核
      分配使用；start.bin 内 argv/bootparam 仅在启动早期被读取，无冲突。

上板: JTAG-AXI（或 rom.vlog 仿真）将 start.bin 写 0x1c000000、
      vmlinux.bin 写 0x1c300000，释放复位即启动到 busybox sh。
文件: vmlinux(strip 后 ELF32) / vmlinux.bin / start.bin / kernel.config
验收: ELF32 LoongArch ✓；AM* 原子指令 = 0 ✓；内嵌 dtb 已验证
      memory=<0x1c000000 0x01000000>、uart clock=100000000 ✓；
      rootfs 含 /bin/ls ✓
