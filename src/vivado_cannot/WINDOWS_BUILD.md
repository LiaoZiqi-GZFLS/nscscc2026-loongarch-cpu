# Windows 原生 SpinalHDL 构建环境

本文档记录本项目在 Windows 上重新生成 Verilog 的已验证环境，以及生成物进入独立 Chiplab 工程的流程。后续流程不依赖 WSL。

## 1. 工具与版本

| 工具 | 要求/已验证版本 |
| --- | --- |
| Windows | Windows 11 64 位 |
| JDK | 17.0.11 |
| sbt runner | 2.0.6，项目实际使用 `1.9.9` |
| Scala | `2.12.16`，由 sbt 自动管理 |
| SpinalHDL | `1.8.1` |
| Vivado | 2023.2 |
| XSim | 2023.2 |

项目版本由以下文件固定：

- `build.sbt`：Scala、SpinalHDL 和其他库版本
- `project/build.properties`：sbt 版本

Vivado 只需要将生成后的 Verilog 和 Xilinx IP 加入工程，不直接编译 Scala。

## 2. 目录关系

建议将 CPU 项目与 Chiplab 分开保存：

```text
C:\workspace\chiplab\                         # 独立 Chiplab，nscscc2026 分支
D:\project\T2026143250012561-t26-perf-submit-trio\  # 本项目
```

Chiplab 必须包含 `IP/myCPU` 子模块：

```powershell
git -C "C:\workspace\chiplab" submodule update --init --recursive
git -C "C:\workspace\chiplab" status --short --branch
git -C "C:\workspace\chiplab" submodule status
```

## 3. 环境变量与 PATH

Vivado 只需将下面目录加入 Windows 用户或系统 `Path`：

```text
C:\Xilinx\Vivado\2023.2\bin
```

不要加入 `bin\unwrapped\win64.o`。

当前 PowerShell 临时设置：

```powershell
$env:Path = "C:\Xilinx\Vivado\2023.2\bin;$env:Path"
```

可选的 Chiplab 环境变量：

```powershell
$env:CHIPLAB_HOME = "C:\workspace\chiplab"
```

`CHIPLAB_HOME` 和项目目录不需要加入 `Path`。

验证工具：

```powershell
java -version
javac -version
sbt --version
vivado -version
xsim -version
xelab -version
xvlog -version
```

Vivado 的 `.bat` 启动脚本可能输出两行 `ECHO 处于关闭状态。`。只要后面能看到对应版本号，这不是错误。

## 4. SpinalHDL 生成 Verilog

进入本目录的 sbt 项目根目录：

```powershell
Set-Location `
  "D:\project\T2026143250012561-t26-perf-submit-trio\src\vivado_cannot"
```

第一次联网构建时解析依赖：

```powershell
sbt -batch -no-colors update
```

普通入口：

```powershell
sbt -batch -no-colors "runMain NOP.Main"
```

Chiplab 适配入口：

```powershell
sbt -batch -no-colors "runMain NOP.MainAdapted"
```

两个入口都会生成：

```text
src\vivado_cannot\build\mycpu_top.v
```

当前 Chiplab AXI 适配场景优先使用 `NOP.MainAdapted`。如果修改了入口或配置，应以项目维护者指定的入口为准，不要混用两个入口生成的网表。

生成成功的标志包括：

```text
SpinalHDL v1.8.1
Generate Verilog
[success]
```

生成时可能出现 `WindowsJNAAffinity` 警告，这是线程亲和性权限提示，不代表生成失败。

## 5. 同步生成物到综合输入

SpinalHDL 输出到 `vivado_cannot/build`，而 Vivado/Chiplab 使用 `src/mycpu`。生成后需要显式复制：

```powershell
Copy-Item `
  ".\build\mycpu_top.v" `
  "..\mycpu\mycpu_top.v" `
  -Force
```

将 CPU 复制到独立 Chiplab：

```powershell
Copy-Item `
  "..\mycpu\*" `
  "C:\workspace\chiplab\IP\myCPU\" `
  -Recurse `
  -Force
```

应确认以下文件存在：

```powershell
Test-Path "C:\workspace\chiplab\IP\myCPU\core_top.v"
Test-Path "C:\workspace\chiplab\IP\myCPU\mycpu_top.v"
Test-Path "C:\workspace\chiplab\IP\myCPU\xilinx_ip\multiplier\multiplier.xci"
```

如果生成或提交内容包含其他 `.xci`/`.xcix`，也必须按项目目录结构同步，不能只复制顶层 Verilog。

## 6. Vivado 工程与综合

重新生成 Verilog 或替换 CPU 后，建议重新创建工程，以清除旧 RTL 的工程缓存：

```powershell
Set-Location `
  "C:\workspace\chiplab\fpga\nscscc-team\run_vivado"

vivado
```

在 Vivado Tcl Console 中执行：

```tcl
cd C:/workspace/chiplab/fpga/nscscc-team/run_vivado
source create_project.tcl
```

检查 CPU 是否进入工程：

```tcl
get_files *core_top.v
get_files *mycpu_top.v
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
report_compile_order -fileset sim_1
```

Vivado 综合入口是 `soc_top`，仿真入口是 `tb_top`。创建工程后可以先运行 Linter，再运行 Behavioral Simulation。

综合和实现：

```tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_timing_summary -file timing_summary.rpt
report_utilization -file utilization.rpt
```

正式性能结果要求 setup WNS 和 hold WNS 均不为负。

## 7. 测试依赖范围

如果测试包已经提供编译好的 `.bin` 和专用 `.tcl`，Windows 原生 Vivado 仿真不需要：

- WSL
- LoongArch 交叉 GCC
- make
- NEMU/QEMU
- Verilator
- FPGA 开发板或串口

只需要完整 Chiplab、测试包和 Vivado/XSim。

只有重新编译性能测试程序时，才需要额外的 Windows 可执行 LoongArch32R 交叉工具链、make 和 C 库。当前项目的 SpinalHDL 生成流程不依赖这些工具。

## 8. 离线迁移

首次构建会从远程仓库下载 sbt、Scala 和 SpinalHDL 依赖。完成一次 `update` 后，离线机器需要保留当前用户的 sbt/Ivy/Coursier 缓存，例如：

```text
C:\Users\<用户名>\.sbt\
C:\Users\<用户名>\.ivy2\
C:\Users\<用户名>\.cache\
```

验证离线构建：

```powershell
sbt -batch -no-colors -offline "runMain NOP.MainAdapted"
```

如果 sbt 仍尝试获取 `sbt 1.9.9`、Scala 或 SpinalHDL，说明对应缓存没有完整迁移。应在联网环境先执行 `sbt update` 和一次生成命令，再迁移缓存；不要修改项目版本来绕过依赖问题。

## 9. 常见问题

### `vivado` 能显示版本但有 ECHO 提示

这是 Vivado Windows 启动脚本对空环境变量的输出。只要命令最终返回版本号即可忽略。

### Vivado 使用了旧 CPU

替换 `IP/myCPU` 后重新执行 `create_project.tcl`，并用 `get_files *mycpu_top.v` 检查工程文件。不要直接复用替换前创建的工程缓存。

### Scala 生成成功但 Vivado 仍使用旧网表

确认已经将：

```text
vivado_cannot\build\mycpu_top.v
```

复制到：

```text
src\mycpu\mycpu_top.v
```

再同步到：

```text
chiplab\IP\myCPU\mycpu_top.v
```

### 生成时报依赖下载错误

先在联网环境执行：

```powershell
sbt -batch -no-colors update
sbt -batch -no-colors "runMain NOP.MainAdapted"
```

再将 sbt/Ivy/Coursier 缓存完整复制到离线环境。
