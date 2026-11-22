@echo off
rem ============================================================
rem  功能测试一键脚本（上板路径, 与官方 CI 同流程）
rem  前置: 开发板已用 USB-JTAG 连接本机并上电
rem  用法:
rem    func_test_board.bat            编译 nscscc_func, 生成比特流并上板判分
rem    set FUNC_BIN=xxx.bin ^& func_test_board.bat   用指定镜像(如大赛给定 bin)
rem    func_test_board.bat -norunbit  跳过比特流生成(复用已有 soc_top.bit)
rem  判读: 末尾打印 func_vio.csv, 三种子全 pass 即通过
rem  耗时: 全流程约 50 分钟(比特流约 45 分钟; -norunbit 时约 5 分钟)
rem ============================================================
setlocal
set ROOT=D:\code\Vivado\Loogarch_workspace_kimi
set SUB=%ROOT%\t26-perf-submit-trio
set CHIPLAB=D:\code\Vivado\Loogarch_workspace_kimi\chiplab
set VIVADO=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
set RUNDV=%CHIPLAB%\fpga\nscscc-team\run_vivado
set SKIPBIT=0
if "%~1"=="-norunbit" set SKIPBIT=1

echo ==== [1/5] 同步最新网表到 chiplab/IP/myCPU ====
copy /y "%SUB%\src\mycpu\mycpu_top.v" "%CHIPLAB%\IP\myCPU\mycpu_top.v" >nul || goto :fail
if not exist "%CHIPLAB%\IP\myCPU\core_top.v" (echo [FAIL] core_top.v missing & goto :fail)
echo OK

echo ==== [2/5] 构建功能测试镜像 ====
if defined FUNC_BIN (
  copy /y "%FUNC_BIN%" "%CHIPLAB%\software\examples\nscscc_func\obj\main.bin" >nul || goto :fail
  echo Use external image: %FUNC_BIN%
) else (
  wsl.exe -d Ubuntu -- bash -lc "export PATH=$HOME/la32r/tc/loongarch32r-linux-gnusf-2022-05-20/bin:$PATH; cd /mnt/d/code/Vivado/Loogarch_workspace_kimi/chiplab/software/examples/nscscc_func && make 2>&1 | tail -3" || goto :fail
)

echo ==== [3/5] 切换 JTAG 下载镜像为 nscscc_func/main.bin ====
wsl.exe -d Ubuntu -- bash -lc "cd /mnt/d/code/Vivado/Loogarch_workspace_kimi/chiplab/fpga/nscscc-team/run_vivado && sed -i 's|^set bin_file \[open \"../../../../software/examples/nscscc_perf/obj/allbench/inst_data.bin\" \"rb\"\]\$|# set bin_file [open \"../../../../software/examples/nscscc_perf/obj/allbench/inst_data.bin\" \"rb\"]|; s|^# set bin_file \[open \"../../../../software/examples/nscscc_func/obj/main.bin\" \"rb\"\]\$|set bin_file [open \"../../../../software/examples/nscscc_func/obj/main.bin\" \"rb\"]|' jtag_axi_master.tcl && grep -n 'set bin_file' jtag_axi_master.tcl" || goto :fail

cd /d %RUNDV% || goto :fail

if %SKIPBIT%==1 goto :program
echo ==== [4/5] 建工程(首次) + 生成比特流(约45分钟) ====
if not exist project\loongson.xpr (
  call "%VIVADO%" -mode batch -source create_project.tcl -log create_project.log -journal create_project.jou || goto :fail
)
call "%VIVADO%" -mode batch -source bit.tcl --tclargs func -log bit.log -journal bit.jou || goto :fail
if not exist project\loongson.runs\impl_1\soc_top.bit (echo [FAIL] bitstream not found & goto :fail)

:program
if %SKIPBIT%==1 echo ==== [4/5] 跳过比特流生成, 复用已有 soc_top.bit ====
echo ==== [5/5] 烧写开发板并运行功能测试(VIO 判分) ====
call "%VIVADO%" -mode batch -source vio.tcl --tclargs project/loongson.runs/impl_1/soc_top.bit project/loongson.runs/impl_1/soc_top.ltx func -log vio_func.log -journal vio_func.jou
set VIO_RC=%errorlevel%

echo.
echo ---- func_vio.csv ----
if exist func_vio.csv type func_vio.csv
if %VIO_RC%==0 (
  echo ========== 上板功能测试全部通过 PASS ==========
  exit /b 0
)
echo ########## 上板功能测试 FAIL/异常, 查 vio_func.log ##########
goto :fail

:fail
echo.
echo ########## 流程失败, 见上方输出 ##########
exit /b 1
