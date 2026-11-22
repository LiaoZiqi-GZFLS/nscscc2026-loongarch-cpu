# NOP-Core SpinalHDL 源码编译说明

本目录（`src/vivado_cannot/`）存放生成 `src/mycpu/mycpu_top.v` 终版网表的完整
SpinalHDL 源码与构建文件（对应提交仓 `t26-submit` 分支 7029bf9 网表；开发基线
nopcore 仓 commit `2857951`，二者内容一致，无补丁链、无增量改动——本源码树
原样 elaborate 即为终版网表）。

## 环境
- JDK 17（OpenJDK 17 验证通过；JDK 11+ 均可，JDK 17 需下文 `--add-opens` 参数）
- sbt 1.9.9（sbt-launch.jar，首次运行自动联网拉取依赖）
- Scala 2.12.16（build.sbt 声明，sbt 自动管理）

## 依赖（build.sbt 声明，Maven Central 自动解析）
- SpinalHDL 1.8.1（`spinalhdl-core` / `spinalhdl-lib` / `spinalhdl-idsl-plugin`）
- scopt 4.0.1
- compiler plugin：scalamacros paradise 2.1.1

## 生成命令（逐条可复现）
```bash
cd src/vivado_cannot            # 本目录，即 sbt 项目根
# 方式一：已安装 sbt
sbt "runMain NOP.Main"
# 方式二：仅有 sbt-launch.jar + JDK17
java --add-opens java.base/java.lang=ALL-UNNAMED \
     --add-opens java.base/java.util=ALL-UNNAMED \
     --add-opens java.base/java.lang.reflect=ALL-UNNAMED \
     -jar sbt-launch.jar "runMain NOP.Main"
```

## 产物位置
- `build/mycpu_top.v` —— 顶层 Verilog（约 12.3 万行）
- 顶层模块名 `mycpu_top`，入口类 `NOP.Main`（`src/Main.scala`）

## 与提交网表的对应关系
本目录源码原样执行上述命令得到的 `build/mycpu_top.v`，与提交仓
`src/mycpu/mycpu_top.v`（7029bf9）为同一生成流产物；除 SpinalHDL 头部注释
（生成时间/Git 信息）与声明顺序等非语义排版差异外逐行一致——本包推送前已
用纯净树重新 elaborate 并与该网表 diff 核验（差异仅头部注释与声明顺序）。

## 许可
本源码树遵循随附 `LICENSE`（NOP-Core 原有许可证，原样保留）。
