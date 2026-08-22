# 决赛演示文档：bootloader + ucore 一键展示

> 分支：`t26-ucore-stable-test` · 目标阶梯：bootloader(5) → ucore(10) → Linux(15/20)
> 本目录是「bootloader + ucore」两幕演示的唯一事实源；`sw/RUNBOOK.md` 为总体 runbook。

## 1. 概览

本演示用一个 Python 脚本（`demo.py`）完成从烧写 bitstream 到 ucore 交互 shell 的
全流程，共五幕：

| 幕 | 内容 | 对应计分 |
|---|---|---|
| 第一幕 | **bootloader**：复位取指 → 串口初始化 → ELF32 解析与搬运 → fw_arg 协议块构建 → DMW/CRMD 地址翻译切换 → 跳转；演示载荷逐项验收交接协议 | bootloader 5 分 |
| 第二幕 | **ucore 启动**：trampoline → 内存管理自检 → 虚拟内存自检 → 调度器 → SFS 挂载 → 用户态 sh | 教学 OS 10 分 |
| 第三幕 | **shell 功能**：help/pwd/ls/mkdir/write/cat/stat/cp/mv/rm/display 自动演示 | 教学 OS 操作 |
| 第四幕 | **UART 文件传输**：主机 → 板载 initrd 文件系统 → 主机 的 put/get 往返（128B 分块 + CRC32 + ACK），逐字节比对 | 教学 OS 操作 |
| 第五幕 | **交互 shell**（可选）：评委/观众自由操作 | 加分项 |

全程所有 Vivado / UART / 交互输出**完整实时打印**到控制台，并原样落盘到
`logs/demo-<时间>/`（不经过任何过滤，方便赛后核对）。

## 2. 文件

| 文件 | 说明 |
|---|---|
| `demo.py` | 一键演示脚本（Windows 原生 / WSL 均可运行） |
| `demo_script.txt` | 第三幕自动执行的 shell 命令与解说词 |
| `load_demo.tcl` | JTAG-AXI 镜像灌入/校验/复位/释放（由 demo.py 调用） |
| `test_offboard.py` | **不上板自检**：假板模拟串口/shell/传输协议，完整跑通五幕流程并断言 PASS（`python test_offboard.py`） |
| `sw/boot/demo_payload.c/.S/.ld` | 第一幕演示载荷（验收 bootloader 交接协议） |
| `sw/ucore/demo/DEMO.md` | 本文档 |

改完 demo.py / demo_script.txt 后，先跑 `python test_offboard.py` 不上板回归（3 个
阶段：完整五幕流程、观察模式、故障快速失败），全部通过再上板。

## 3. 快速开始（一键）

### 前置条件（一次性准备）

1. **硬件**：开发板接好 JTAG 与独立 UART（FTDI `0403:6010`/`0403:6001`），上电。
2. **Windows 原生环境**（推荐，与 release/ 已验证流程一致）：
   - Vivado 2023.2（`C:\Xilinx\Vivado\2023.2`），`vivado.bat` 在 PATH 或由脚本自动定位；
   - `hw_server` 运行在 3121 端口（脚本可用 `--start-hw-server` 自动拉起）；
   - Python 3 + `pip install pyserial`。
3. **WSL 环境**（与 board_stability.sh 一致的替代路径）：USBIP 转发两个 FTDI 设备、
   安装 cable driver、修复 `/dev/bus/usb` 与 `/dev/ttyUSB*` 权限（见仓库根 `Readme.md`），
   `hw_server` 跑在 3121/3122。无 pyserial 时脚本自动退回 termios 实现。
4. **构建镜像**（有 LA32R 工具链的机器执行一次，之后可跳过）：
   ```sh
   cd sw/boot && make && make demo_payload.elf   # boot.bin + demo_payload.elf
   cd sw/ucore && ./build.sh                     # out/ucore.bin
   ```
   demo.py 预检发现镜像缺失时会自动尝试构建（Windows 下自动经 `wsl.exe` 转发）。

### 一键运行

```bash
python sw/ucore/demo/demo.py                 # 完整五幕（含文件传输）
python sw/ucore/demo/demo.py --no-program    # 不重烧 bit（复用板子当前 bit）
python sw/ucore/demo/demo.py --no-load       # 不灌镜像，只接串口观察
python sw/ucore/demo/demo.py --acts ucore    # 只演示 ucore（跳第一幕）
python sw/ucore/demo/demo.py --acts bootloader --no-transfer --no-scripted
python sw/ucore/demo/demo.py --interactive   # 结束时直接进入交互 shell
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--port` | auto | 串口（auto 按 FTDI VID:PID 自动识别；COM5 / `/dev/ttyUSB2`） |
| `--hw-server` | localhost:3121 | hw_server 地址 |
| `--bit` | `bit/sys_test/bit/sys_soc_top_100mhz.bit` | bitstream |
| `--payload` | `sw/boot/demo_payload.elf` | 第一幕载荷（可换 Linux vmlinux 等） |
| `--act1-marker` | PAYLOAD_OK | 第一幕通过标记（换 Linux 时改 `Linux version`） |
| `--act1-timeout` / `--act2-timeout` | 60 / 120 s | 各幕等待超时 |
| `--cmd-delay` / `--char-delay` | 0.005 / 0.02 s | shell 命令 / 文件传输逐字符发送间隔 |
| `--log-dir` | `logs/demo-<时间>` | 日志目录 |

## 4. 演示剧本（Storyboard）

预计总时长 **6–8 分钟**（烧写 1–2 分钟 + 各幕 1 分钟左右）。

### 第一幕 bootloader（约 1 分钟）

JTAG-AXI 把 `boot.bin` 灌到复位入口 `0x1C000000`、演示载荷 ELF 灌到暂存区
`0x1C400000`，释放 CPU 后串口依次出现（解说词由脚本自动打印）：

```
NSCSCC2026 mini bootloader v0.1 (LA32R/chiplab)
DDR      : 0x1c000000 size 16 MB
UART     : 0x1fe001e0 pclk 100 MHz, 115200 8N1 (div=54)
Image    : probe 0x1c400000
  LOAD 0x1c200000 filesz=0x00000xxx memsz=0x00000xxx
fw_arg   : argc=2 argv=0xa1cff000 bpi=0xa1cff140
cmdline  : console=ttyS0,115200
MEM list : SYSRAM 0x1c000000 size 0x01000000
Jumping to entry 0xbc200000 ...
```

| 板端输出 | 解说要点 |
|---|---|
| mini bootloader banner | 复位取指 0x1C000000；串口 16550 初始化（100MHz → 115200 分频 DLL=54） |
| `Image    : probe` | 从暂存区 0x1C400000 探测下一阶段镜像（JTAG-AXI 预灌） |
| `  LOAD 0x1c200000` | ELF32 Program Header 解析；PT_LOAD 搬运（kseg 地址折叠为物理地址）；.bss 清零 |
| `fw_arg` / `MEM list` | la32r-Linux fw_arg 协议块（DDR 顶端 0x1CFF0000）：a0/a1/a2、BPI 签名、MEM 内存链表（含校验和） |
| `Jumping to entry` | 配置 DMW0/DMW1 直接映射窗口 → dbar/ibar 屏障 → CRMD.PG=1 打开地址翻译 → 跳转 |

随后演示载荷在 `0xBC200000` 运行，逐项打印 argv/cmdline/BPI/MEM 并验证校验和，
数码管显示 **B007**，最后输出 `PAYLOAD_OK` —— bootloader 交接协议端到端验收通过。

### 第二幕 ucore 启动（约 30 秒）

CPU 复位后把 `ucore.bin` 直接灌到 `0x1C000000` 释放（真板已验证拓扑），串口出现：

```
(THU.CST) os is loading ...
Special kernel symbols:
  entry  0xBC000134 (phys)
...
check_alloc_page() succeeded!
check_pgdir() succeeded!
check_boot_pgdir() succeeded!
check_slab() succeeded!
...
sched class: stride_scheduler
proc_init succeeded
sfs: mount: 'simple file system' (71/16/87)
vfs: mount disk0.
kernel_execve: pid = 2, name = "sh".
user sh is running!!!
```

| 板端输出 | 解说要点 |
|---|---|
| `os is loading` | 入口 trampoline 配置 DMW/CRMD 完成 DA→PG 切换 |
| `check_alloc_page` | 物理内存管理（first-fit 分配器）自检 |
| `check_boot_pgdir` | 虚拟内存管理：页目录/页表/缺页处理（依赖自研核 TLB 与异常机制） |
| `sched class: stride_scheduler` | 进程调度器初始化 |
| `sfs: mount` | SFS 文件系统从 initrd 挂载 |
| `user sh is running` | 第一个用户进程 sh 启动 |

### 第三幕 shell 功能（约 2 分钟）

脚本自动执行 `help → pwd → ls → mkdir demo → cd demo → write hello.txt → cat →
stat → cp → mv → ls → rm → cd / → display C0DE2026`，每步打印解说词；
`display` 时提示评委看数码管（显示 `C0DE2026`）。

### 第四幕 UART 文件传输（约 1 分钟）

脚本生成 256 字节测试文件：`xput /demo.bin` 上传（128B 分块、十六进制编码、
逐块 CRC32、ACK 重传）→ `cat /demo.bin` 读回 → `xget /demo.bin` 下载 → 与原件
逐字节 `cmp`。传输期间数码管显示 `F1`/`F2` 进度与 `A1`/`A2` 结果。

### 第五幕 交互（自由发挥）

脚本询问是否进入交互 shell（`--interactive` 直接进入）。评委可敲
`help / ls / cat hello.txt / display 88888888` 等；**Ctrl-]** 退出（板子继续运行）。

## 5. 日志（完整输出）

每次运行生成 `logs/demo-<时间>/`：

| 文件 | 内容 |
|---|---|
| `main.log` | 主机侧全流程日志（步骤、解说词、Vivado 回显） |
| `uart.log` | 串口**逐字节原始流**（与板端输出完全一致） |
| `program-bit.log` / `act1-load.log` / `act2-reset.log` / `act2-load.log` | 各 Vivado 步骤完整输出 |
| `transfer-src.bin` / `transfer-dst.bin` | 第四幕往返文件 |

赛后核对：`main.log` 与 `uart.log` 可完整还原演示过程。

## 6. 设计说明：为什么 bootloader 与 ucore 分两幕（重要）

bootloader 默认 ELF 模式会把镜像的 PT_LOAD 段搬到其物理链接地址。ucore 链接于
`0xBC000000`，kseg 折叠后为 `0x1C000000` —— **与 bootloader 自身运行地址完全重叠**。
bootloader 全程运行在 DA 模式（CRMD.DATF=0，取指不缓存），拷贝进行到自身代码段时
会被覆写、立即失控；链式加载 ucore 从未在真板验证过（所有真板日志均为直接灌
`0x1C000000` 的 PMON 式拓扑）。

因此演示采用两幕：第一幕用链接在 `0xBC200000`（折叠后 `0x1C200000`，避开
bootloader/暂存区/fw_arg 区）的演示载荷完整展示 bootloader 的 ELF 加载与 fw_arg
协议；第二幕用真板已验证拓扑启动 ucore。若需要真正的 bootloader→ucore 单链，
正确做法是给 bootloader 增加 stage-2 搬运器（先把镜像拷到 DDR 顶端安全区执行，
再覆写 `0x1C000000`），属于可选后续工作，不计入本次演示。

> 补充：bootloader ELF 模式加载 **Linux**（board-16m 变体，链接 `0xBC300000` → 物理
> `0x1C300000`）没有自覆写问题，可作 15/20 分链演示：
> `demo.py --payload sw/linux/out/board-16m/vmlinux --act1-marker "Linux version" --act1-timeout 300`。

## 7. 故障排查

| 现象 | 排查 |
|---|---|
| 串口乱码 | 波特率不匹配：确认 sys_clk=100MHz；乱码首选排查项（README 校准法） |
| `打不开串口` / 自动识别失败 | `--port` 显式指定；检查串口线、是否被其他终端占用（传输期间只能有一个读进程） |
| `无法连接 hw_server` | 加 `--start-hw-server`；或手动启动（Windows: `hw_server.bat`；WSL: `sudo .../hw_server -d -s tcp::3121`） |
| 烧写/灌入失败 | 看 `logs/demo-<时间>/act*-load.log`；确认 JTAG 线、`hw_axi_1` 存在（bit 未烧对时不存在） |
| 第一幕 `BOOT FAILED: halt` | 暂存区镜像不是合法 ELF32；确认灌的是 `demo_payload.elf` 而非裸 bin |
| 第一幕无 banner | 复位入口没灌上 `boot.bin`；看 `VERIFY` 行是否 expected==actual |
| 第二幕无输出 | ucore.bin 校验失败 / 释放失败；`uart.log` 为空则查串口设备选择 |
| 第三幕某条命令超时 | 增大 `--cmd-timeout`/`--cmd-delay`；确认 shell 处于提示符状态 |
| 第四幕传输失败 | 增大 `--char-delay`（0.02→0.03）；确认传输期间没有第二个串口读进程 |
| ucore 启动中途 `kernel panic` | 查 uart.log 中 panic 字样；TLB/cache 相关按 RUNBOOK 风险矩阵定位 |

## 8. 赛前检查清单

- [ ] `python test_offboard.py` 不上板自检全绿
- [ ] WSL/Windows 各跑通一次 `demo.py` 全流程，记录耗时
- [ ] `bit/sys_test/bit/sys_soc_top_100mhz.bit` 与板子当前 bit 一致（WNS ≥ 0）
- [ ] 备份 `sw/boot/boot.bin`、`sw/boot/demo_payload.elf`、`sw/ucore/out/ucore.bin`
- [ ] 演示机串口不被其他程序占用（关闭 picocom/串口助手）
- [ ] 完整日志目录 `logs/demo-<时间>/` 归档（复赛要求留存验证记录）

## 9. 真板测试记录

**2026-08-22（Windows 原生：COM3=UART、hw_server 3121、xc7a200t）**

1. 第一轮（烧 bit + 第一幕）：bootloader 链**真板完整跑通** —— banner、
   `LOAD 0x1c200000 filesz=0xfb8`、fw_arg、MEM list、`Jumping to entry 0xbc200000`，
   载荷开始执行。发现并修复**载荷 bss 顺序 bug**：`demo_start.S` 先把 a0/a1/a2
   握手寄存器存入 .bss，随后清 .bss 时把刚存的值清掉（载荷打印 argc=0/bpi=0）。
   修复：先清 .bss 再保存握手寄存器（已重建并过 offboard 自检）。
2. 真板实测 bootloader 输出与文档一致：`argv=0xbcff0000`、`bpi=0xbcff0140`
   （KVIRT=0xa0000000|phys，phys≥0x10000000 时位或后为 0xbcffxxxx 而非 0xa1cffxxxx）。
3. 第二轮（--no-program 复用 bit）：两幕镜像 JTAG 灌入+校验均通过、CPU 释放，
   但 UART **0 字节**（第一轮正常）。DTR 翻转无效。板子被占用，后续诊断
   待做：JTAG-AXI 读 CONFREG 0x1faff050（若为 0xB0070000 说明载荷已跑，问题在
   FTDI 串口链路，可 USB 重新枚举）；再不行重新烧 bit 走完整冷启动。
4. 工具链：本机 WSL `/home/lazybones/la32r/tc/loongarch32r-linux-gnusf-2022-05-20`
   （boot Makefile 已加入自动探测）。

## 9. 归档到 show/

决赛展示包 `show/`（`show.zip` 同构）补充内容：

- `show/software/boot/`：`demo_payload.c`、`demo_start.S`、`demo_payload.ld`、更新后的 `Makefile`
- `show/software/ucore/demo/`：`demo.py`、`demo_script.txt`、`load_demo.tcl`、本 `DEMO.md`
- `show/doc/demo.md`：本文档副本
