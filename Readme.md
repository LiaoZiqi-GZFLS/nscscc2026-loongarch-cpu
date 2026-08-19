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
