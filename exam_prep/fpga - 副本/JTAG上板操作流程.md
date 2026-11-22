# JTAG 上板操作流程（功能测试 / 自定义指令测试）

> 适用：2026 龙芯杯决赛现场，开发板 Artix-7 (xc7a200tfbg676-2)，Vivado 2023.2。
> 本流程与官方 CI 上板测试完全同路径（vio.tcl + jtag_axi_master.tcl），已实测 CI 通过记录：
> `func_vio.csv` 三种子全 pass，result=0x3A00003A。

---

## 1. 流程总览

```
[WSL] 汇编测试镜像 main.bin          [Windows/Vivado]
        │                                    │
        ▼                                    ▼
  nscscc_func make ──────►  建工程 create_project.tcl（首次约 1 分钟）
        │                                    │
        │                    比特流 bit.tcl（约 45 分钟）
        │                     → soc_top.bit + soc_top.ltx
        │                                    │
        └──────────►  vio.tcl 一键上板 ◄─────┘
                       ① 烧写 bit（Hardware Manager）
                       ② VIO 设开关 0xF0（func 模式）
                       ③ 全系统复位，等 DDR 就绪
                       ④ JTAG AXI 写 main.bin 到 DDR 0x1c000000
                          （先 WriteReg 0x80000000 复位 CPU，
                            写完 WriteReg 0x40000000 释放复位）
                       ⑤ VIO 轮询 num_data，判 PASS/FAIL
                       → 输出 func_vio.csv
```

**关键点**：程序镜像不进 bit 流，而是烧写后由 JTAG AXI Master 直接写 DDR。
所以**换测试程序不需要重新生成比特流**——只要重跑第 ④⑤ 步（见 3.3 节），几分钟一轮。

---

## 2. 前置检查（连板后）

1. 开发板 USB-JTAG 连接电脑，板子上电。
2. 确认板载 8 位拨码开关位置可拨（func 模式由 VIO 虚拟开关设定，物理开关保持默认即可）。
3. 可选：串口线接好，串口助手 **115200 8N1** 打开（测试过程有 UART 打印，辅助判读）。

比特流位置（脚本会自动找）：

```
chiplab\fpga\nscscc-team\run_vivado\project\loongson.runs\impl_1\soc_top.bit
同目录 soc_top.ltx   ← VIO 探针文件，必须与 bit 同一次实现产出
```

---

## 3. 三种操作方式

### 3.1 一键脚本（推荐）

正常 cmd 窗口（**不要用 git bash 调 Vivado 批处理**）：

```bat
rem 全流程：编译镜像 + 建工程 + 比特流 + 上板判分（约 50 分钟）
D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\func_test_board.bat

rem 已有 soc_top.bit，只换测试程序重跑上板（约 5 分钟）
D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\func_test_board.bat -norunbit

rem 用大赛给定的测试镜像（自定义指令考试）：
set FUNC_BIN=D:\path\to\大赛给定.bin
D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\func_test_board.bat -norunbit
```

结束判读：
- 打印 `========== 上板功能测试全部通过 PASS ==========` 即通过；
- 同目录 `func_vio.csv` 应有 F0/FF/A5 三个种子全 `pass`，`result=3A00003A`。

### 3.2 手工 Tcl（脚本失败时的备用路径）

正常 cmd 窗口，`cd` 到 `chiplab\fpga\nscscc-team\run_vivado`：

```bat
C:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source vio.tcl ^
  --tclargs project/loongson.runs/impl_1/soc_top.bit ^
            project/loongson.runs/impl_1/soc_top.ltx func
```

vio.tcl 参数依次为：`<bit文件> <ltx探针文件> <func|perf> [压力种子]`。

### 3.3 只换程序不重跑全流程（快速迭代）

前提是板子已烧好 bit 且没断电重配：

1. 把新镜像放到 `chiplab\software\examples\nscscc_func\obj\main.bin`
   （或改 `jtag_axi_master.tcl` 第 61 行的 `set bin_file` 路径）；
2. 重跑 3.2 的命令即可——vio.tcl 会先复位整个系统再经 JTAG 重写 DDR，
   DDR 内容复位后仍保留，但脚本每次都会重新下载，无需手工干预。

### 3.4 Vivado GUI 手工烧写（最兜底）

1. 打开 Vivado → Flow → Open Hardware Manager → Open Target → Auto Connect；
2. 右键 `xc7a200t_0` → Program Device → 选 `soc_top.bit`（ probes 选 `soc_top.ltx` ）；
3. 烧写完成后在下方 **Tcl Console** 里：
   ```tcl
   cd D:/code/Vivado/Loogarch_workspace_kimi/chiplab/fpga/nscscc-team/run_vivado
   source jtag_axi_master.tcl    ;# 下载程序到 DDR 并释放 CPU 复位
   ```
4. 观察板载数码管/LED 或串口输出判分。

---

## 4. 判分依据

| 通道 | 通过标志 |
|---|---|
| VIO `num_data` 探针 | 功能测试全过 = `0x3A00003A`（脚本自动判） |
| VIO `led_rg0` 探针 | 1=PASS，2=FAIL，0=运行中 |
| 板载双色 LED | 对应 led_rg0（绿/红） |
| 板载数码管 | num_data 低 8 位实时显示当前测试点编号，逐项递增 |
| UART 串口(115200 8N1) | 测试结束打印结果，发 0xFF 表示 END |

自定义指令测试以**大赛给定的判分方式**为准（往年为仿真 coe + 上板 LED/验收老师确认），
硬件通道行为与上表一致。

---

## 5. 常见故障排查

| 现象 | 原因与处理 |
|---|---|
| `open_hw_target` 报错 / 找不到设备 | USB 线没插好或板子没上电；设备管理器看 USB Serial/Digilent；重插后重跑 |
| `Required VIO ... probe was not found` | bit 与 ltx 不是同一次实现产物；或烧成了旧 bit。用同目录配对的 bit+ltx |
| DDR readiness timeout | MIG 校准失败：给板子断电重启再跑；检查 bit 是否为本 SoC 工程产出 |
| num_data 一直为 0 | CPU 没跑：确认 JTAG 下载完成（jtag_axi_master.tcl 无 ERROR）；手动再 source 一次 |
| 结果停在某个测试点编号 | 该测试点失败/卡死：记下数码管编号 n=NN，去 nscscc_func 查对应测试项定位 |
| `Labtoolstcl 44-481` 大量刷屏 | 正常现象（JTAG 写数据回显），脚本已屏蔽 |
| vivado.bat 在 git bash 里秒退 rc=1 | 已知问题：loader 依赖完整 cmd 环境。**一律在正常 cmd 窗口运行脚本** |

---

## 6. 性能测试（备用参考）

同一脚本体系支持 perf：

```bat
rem vio.tcl 第四个参数换成 perf；镜像为 nscscc_perf/obj/allbench/inst_data.bin
```

考试只考功能正确性，perf 路径一般不需要；如需跑，先把 `jtag_axi_master.tcl`
的 `set bin_file` 切到 perf 行（func_test_board.bat 的 sed 只负责切到 func）。

---

## 附：涉及文件清单

| 文件 | 作用 |
|---|---|
| `exam_prep\fpga\func_test_board.bat` | 一键上板（含镜像编译、镜像切换、烧写判分） |
| `chiplab\...\run_vivado\vio.tcl` | 烧写 + VIO 控制 + 判分主逻辑（官方 CI 同款） |
| `chiplab\...\run_vivado\jtag_axi_master.tcl` | JTAG AXI 写 DDR 镜像（bin 路径在第 60–62 行） |
| `chiplab\...\run_vivado\create_project.tcl` / `bit.tcl` | 建工程 / 生成比特流 |
| `chiplab\software\examples\nscscc_func` | 功能测试镜像来源（WSL make） |
