verilator-flow 变体（chiplab verilator 官方流程）
================================================
布局: RAM 物理 0 起 128MB（内嵌 DTS loongson32_ls.dts memory 节点）
内核: 链接/加载 物理 0x300000（虚址 0xa0300000 缓存窗口），kernel_entry 0xa0b84b10
启动: CPU 复位 @0x1c000000 -> start.bin -> DMW(0xa0000011/0x80000001, PG=1)
      -> 跳 kernel_entry；a0=2 a1=argv a2=bootparam(全0)
命令行: console=ttyS0,115200 rdinit=/init loglevel=8（UART 时钟 100MHz，
       内核 8250 算除数 54，与 bootloader 一致）
文件:
  vmlinux       ELF32 LoongArch（strip 后，含内嵌 initramfs）
  vmlinux.bin   裸二进制（rom.vlog 用 boot/mkimage.sh 再生成，约 40MB 未入库）
  start.bin     引导 stub（768B @0x1c000000，内嵌 argv/cmdline/bootparam）
  kernel.config 完整内核配置（la32_defconfig + CONFIG_INITRAMFS_SOURCE）
根文件系统:  ../rootfs.cpio.gz 已内嵌进内核（busybox sh/ls/mount/cat 等）
验收: ELF32 LoongArch ✓；AM* 原子指令 = 0 ✓；rootfs 含 /bin/ls ✓
