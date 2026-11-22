## 初赛提交要求

1. **截止时间**：北京时间 **2026 年 8 月 5 日 23 时 59 分 59 秒**。
2. **初赛评定指标**：初赛仅关注 `score.xlsx` 中的“系统计数器比值”和“功能分”。
3. **设计文档**：必须按照赛事要求在仓库根目录提交设计文档 `design.pdf`。
4. **成绩认定**：成绩以截止时间前由 CI 流水线实际测试得到的分数为准。超过截止
   时间后，参赛者不能再触发新的 CI 流水线。
5. **性能测试时序要求**：性能测试的 setup WNS 和 hold WNS 均不能为负，否则该
   次性能测试成绩无效。
6. **提交分支**：禁止直接向 `master` 分支上传或推送参赛代码。请基于 `master`
   新建分支，并在新分支中提交代码和触发 CI。
7. **Chiplab 版本**：比赛平台使用 Chiplab 的
   [`nscscc2026` 分支](https://gitee.com/loongson-edu/chiplab/tree/nscscc2026/)。

## 文件目录结构
- src/
    - mycpu/           【vivado支持的CPU IP完整源码】
        - xilinx_ip/   【CPU IP 内部使用到的 xilinx ip 】【可选】
            - IP名称    
                - *.xci\<x\>   
    - vivado_cannot/   【可选】
    - perf_clock.json  【性能测试CPU主频配置】
- bit/                 【存放各项测试生成好的bit文件】
- show/                【决赛展示内容，要求myCPU与src/目录里完全一致】
- score.xlsx
- .gitlab-ci.yml CI/CD 【配置文件（禁止修改）】
- design.pdf           【必须提交的设计文档】


## 注意事项
1. **master**分支是受保护的模板分支，请基于master分支建立自己的分支，进行设计文件的添加；如果master分支有变动，请及时合并master分支更新。  
2. **禁止修改** `.gitlab-ci.yml` 与 `tcl` 脚本。`.gitlab-ci.yml` 只引用赛事统一维护的外部 CI 模板；请严格按照模板要求放置文件，否则可能导致无法生成工程与产物。
3. **Xilinx IP 使用规范**  
　　- 若调用了 Xilinx IP（例如 Block RAM IP），需将定制文件 `*.xci`（或 `*.xcix`）放置于 `src/mycpu/xilinx_ip/` 目录下。  
　　- 每个 IP 独立文件夹存放，且文件夹中**仅包含** `.xci` 或 `.xcix` 文件，不得包含综合生成的文件。  
4. **性能测试 CPU 主频**
　　- 在 `src/perf_clock.json` 的 `cpu_clk_mhz` 字段中填写主频，允许范围为 10–200 MHz。
　　- 学生不再提交平台 PLL XCI；CI 根据该字段生成 Clock Wizard 配置，并固定系统时钟和 DDR 参考时钟。
5. **非 Vivado 支持语言**
　　- 若使用 Vivado 无法直接综合的硬件描述语言（SpinalHDL、Chisel），需提供：  
　　　　- 完整源码  
　　　　- 编译说明  
6. **参考与借鉴声明**
　　- 若 CPU 设计中参考了任何资料（如教材），需在文档中明确声明。

## Chiplab JTAG 功能测试上板

### WSL 通过 USBIP 直接连接开发板（已验证）

此模式不使用 Windows Vivado 或 Windows `hw_server`。Windows 只通过 `usbipd`
将 USB 设备转发到 WSL：`0403:6010` 是 FT2232 JTAG 复合设备，`0403:6001`
是独立 UART。`/dev/ttyUSB*` 只能用于 UART，不能替代 JTAG 烧写。

在 Windows PowerShell 中关闭可能占用 JTAG 的程序，并按 `usbipd wsl list` 显示
的实际 BUSID 重新转发设备：

```powershell
Stop-Process -Name vivado -Force -ErrorAction SilentlyContinue
Stop-Process -Name hw_server -Force -ErrorAction SilentlyContinue
usbipd wsl detach --busid 2-2
usbipd wsl detach --busid 2-3
usbipd wsl attach --busid 2-2
usbipd wsl attach --busid 2-3
```

WSL 中执行 `lsusb`，必须同时看到 `0403:6010` 和 `0403:6001`。首次使用时安装
Vivado Linux cable driver：

```shell
sudo /tools/Xilinx/Vivado/2023.2/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers
```

USBIP 重新 attach 后，检查 `0403:6010` 的总线和设备号。例如 `lsusb` 显示
`Bus 001 Device 008: ID 0403:6010`，则放开对应原始 USB 节点以及 UART 节点权限：

```shell
sudo chmod 666 /dev/bus/usb/001/008
sudo chmod 666 /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2
```

总线和设备号会在重新 attach 后变化，不能固定照抄 `001/008`。如果节点仍为
`root:root 0600`，普通用户运行的 `hw_server` 无法通过 libusb 发现 JTAG target。

若默认 `3121` 报 `Address already in use`，可使用已验证的备用端口 `3122`：

```shell
sudo /tools/Xilinx/Vivado/2023.2/bin/hw_server -d -s tcp::3122
```

保持该终端运行，在另一终端验证：

```shell
vivado -mode tcl
```

```tcl
open_hw_manager
connect_hw_server -url localhost:3122 -allow_non_jtag
refresh_hw_server [get_hw_servers]
set targets [get_hw_targets -quiet]
puts "TARGET_COUNT=[llength $targets]"
current_hw_target [lindex $targets 0]
open_hw_target
puts "DEVICES=[get_hw_devices -quiet]"
```

只有输出 `TARGET_COUNT=1` 且设备包含 `xc7a200t_0` 后才执行烧录：

```shell
HW_SERVER_URL=localhost:3122 FUNC_TIMEOUT=120 sh ./chiplab_func_board.sh
```

2026-08-19 实板验证结果为 Digilent target `210357A7D00EA`、设备
`xc7a200t_0`，最终输出 `CHIPLAB_FUNC_PASS`。本地非默认端口会被脚本按现有服务
处理，因此必须先手动启动该端口的 `hw_server`。

### Windows 原生 hw_server

如果 JTAG 由 Windows 原生 `hw_server` 管理，可在 WSL 中指定远程服务：

```shell
HW_SERVER_URL=WINDOWS_HOST_IP:3121 sh ./chiplab_func_board.sh
```

此模式不会在 WSL 中启动本地 `hw_server`。Windows 负责访问 USB JTAG，WSL
继续负责 Vivado Tcl 客户端、镜像文件和构建。

脚本会在执行 Vivado 前自动检查 `WINDOWS_HOST_IP:3121` 是否可达；成功时输出
`hw_server reachable`，失败时停止并提示检查 Windows 服务、防火墙和 WSL 主机地址。

连接开发板 JTAG 后，在仓库根目录执行快速自动验收：

```shell
sh ./chiplab_func_board.sh
```

脚本烧写 `bit/func_test/func_soc_top.bit`，通过 JTAG AXI 将 chiplab 的
`nscscc_func/obj/main.bin` 下载到 `0x1c000000`，并轮询 CONFREG 数码管寄存器
`0x1faff050`。正确终态是数码管显示 `3A 00 00 3A`，两颗双色 LED 均为绿色。

该功能程序不输出可读 UART 文本。结束时它只向 CONFREG 虚拟 UART
`0x1fafff10` 写入一个 `0x00` 完成标记；当前 bitstream 的 VIO 探针也未连接该
信号。因此，应以日志中的 `NUM_DATA`、`BOARD_STATUS` 和 `CHIPLAB_FUNC_PASS`
判断结果。Vivado 输出的 `WRITE DATA` 是 JTAG AXI 下载内容，不是 UART 数据。

以约一秒一个测试点的速度观察数码管递增：

```shell
FUNC_SWITCH=C0 FUNC_TIMEOUT=120 sh ./chiplab_func_board.sh
```

最慢观察模式每个测试点约 14 秒，完整测试需要约 13 分钟：

```shell
FUNC_SWITCH=00 FUNC_TIMEOUT=900 sh ./chiplab_func_board.sh
```
