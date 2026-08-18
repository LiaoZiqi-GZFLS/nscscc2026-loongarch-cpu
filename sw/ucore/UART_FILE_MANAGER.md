# uCore UART 文件管理归档

## 归档范围

本归档记录当前已在 nscscc-team 开发板上验证的 uCore UART 文件管理功能：

- shell 内建文件命令；
- 主机与 uCore 间的 UART 二进制文件上传、下载；
- 八位七段数码管的状态与进度显示；
- 对应构建、上板和运行命令。

ALIENTEK 4.3 英寸 TFTLCD 尚未接入当前 SoC，不属于本归档的已实现范围。接入
TFTLCD 需要新增 FPGA 引脚约束、LCD 时序/帧缓冲控制器和 uCore 显示驱动。

## 实现位置

| 模块 | 文件 |
|---|---|
| shell 文件命令和板端传输协议 | `user/sh.c` |
| 用户态文件、目录和显示接口 | `user/libs/file.[ch]`、`user/libs/dir.c` |
| 用户态系统调用包装 | `user/libs/syscall.[ch]` |
| 内核系统调用 | `kern/include/unistd.h`、`kern/syscall/syscall.c` |
| VFS 路径和命名空间操作 | `kern/fs/vfs/vfslookup.c`、`vfsfile.c`、`inode.h` |
| SFS 创建、删除、重命名和多级路径 | `kern/fs/sfs/sfs_inode.c` |
| 主机传输工具 | `tools/ucore_uart.py` |
| 可启动产物 | `out/ucore.bin`、`out/ucore.elf`、`out/ucore.elf.stripped` |

## 构建与上板

在 `sw/ucore` 目录构建：

```shell
sh ./build.sh
```

连接 JTAG 和 UART 后进行一次冷启动验收：

```shell
UART=/dev/ttyUSB0 ROUNDS=1 BOOT_TIMEOUT=45 sh ./board_stability.sh
```

连续稳定性测试：

```shell
UART=/dev/ttyUSB0 ROUNDS=3 BOOT_TIMEOUT=45 sh ./board_stability.sh
```

验收脚本会烧写系统测试 bitstream、下载 `out/ucore.bin` 到物理地址
`0x1c000000`，释放 CPU 并检查 `check_boot_pgdir() succeeded` 和
`user sh is running` 两个启动标记。

## shell 文件命令

串口参数为 115200 8N1。进入 `$` 提示符后可执行：

```text
help
pwd
ls
mkdir data
cd data
write hello.txt hello from uCore
cat hello.txt
stat hello.txt
cp hello.txt copy.txt
mv copy.txt moved.txt
rm moved.txt
cd /
```

`ls` 和 `cat` 由常驻 shell 直接执行，避免文件管理流程依赖额外用户进程。
`write` 将后续参数用空格连接，并在末尾写入换行。`rm` 当前只删除普通文件；
不支持递归删除目录。`mv` 当前不覆盖已存在的目标，也不移动目录。

## UART 文件传输

主机工具仅依赖 Python 3 标准库，默认串口为 `/dev/ttyUSB0`。

上传：

```shell
python3 tools/ucore_uart.py --port /dev/ttyUSB0 put ./local.bin /upload.bin
```

下载并比较：

```shell
python3 tools/ucore_uart.py --port /dev/ttyUSB0 get /upload.bin ./downloaded.bin
cmp ./local.bin ./downloaded.bin
```

传输期间必须关闭 `minicom`、`screen`、`picocom` 等其他串口读取程序。当前 SoC
没有连接 UART RX 中断，uCore 通过 100Hz 时钟中断轮询接收，因此主机工具按字符
间隔 12ms 发送，不能用普通程序一次性突发写入整行。

### 协议

上传由主机先发送：

```text
xput PATH SIZE FILE_CRC32
```

随后以最多 128 字节为一块发送：

```text
D SEQ LENGTH CHUNK_CRC32 HEX_DATA
```

板端返回 `ACK SEQ`。完成后返回 `XDONE FILE_CRC32`，失败返回 `XERR CODE`。
上传先写入 `PATH.part`，整文件长度和 CRC32 验证通过后再重命名为目标文件。

下载由主机发送 `xget PATH`，板端先返回：

```text
XMETA SIZE FILE_CRC32
```

随后使用相同 `D` 数据块格式，每块等待主机 `ACK SEQ` 后继续。

协议采用十六进制编码而不是原始二进制，原因是当前 console 输入会丢弃 NUL，
输出还会将 LF 转换为 CRLF。逐块 CRC32、整文件 CRC32 和 stop-and-wait ACK 用于
检测串口丢字节或损坏。

## 数码管显示

当前开发板接口是八位七段十六进制数码管，不是 LCD。shell 可直接写入 32 位值：

```text
display C0DE2026
display 1234ABCD
```

uCore 使用 CONFREG 的 uncached 地址 `0x9faff050`。文件传输自动显示：

| 数码管值 | 含义 |
|---|---|
| `F1xxxxxx` | 上传中，低 24 位为已接收字节数 |
| `F2xxxxxx` | 下载中，低 24 位为已发送字节数 |
| `A1xxxxxx` | 上传成功 |
| `A2xxxxxx` | 下载成功 |
| `E1xxxxxx` | 上传失败，低位为错误码 |
| `E2xxxxxx` | 下载失败，低位为错误码 |

## 存储语义与限制

文件系统是链接进内核镜像的 RAM initrd。运行时创建和修改的文件只在本次开机
期间有效；复位、重新烧写或重新加载 uCore 后恢复为构建时内容。`fsync` 只同步
RAM 中的 SFS 元数据，不会写入 Flash、SD 卡或主机文件。

当前未实现：

- 掉电持久化；
- 删除目录和递归删除；
- 覆盖式重命名、目录移动；
- 权限、用户、时间戳；
- TFTLCD 图形或文本终端。

## 已验证结果

2026-08-18 在真实开发板上完成：

- 新镜像冷启动并进入 shell；
- `mkdir/cd/pwd/write/cat/stat/cp/mv/ls/rm/display` 命令序列通过；
- 300 字节随机二进制文件上传成功；
- 同一文件下载成功；
- 上传源文件和下载文件执行 `cmp` 一致；
- 分块 CRC32 和整文件 CRC32 均一致；
- 构建产物为 LoongArch ELF32，入口 `0xbc000000`；
- 镜像中 AM 原子指令和浮点指令计数均为 0。
