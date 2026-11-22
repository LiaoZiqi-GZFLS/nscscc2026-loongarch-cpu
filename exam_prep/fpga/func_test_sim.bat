@echo off
rem ============================================================
rem  功能测试一键脚本（xsim 仿真路径，无需开发板）
rem  用法:
rem    func_test_sim.bat            编译 nscscc_func 并仿真全部 81 项
rem    set FUNC_BIN=xxx.bin ^& func_test_sim.bat   用指定镜像(如大赛给定 bin)
rem  判读: 末尾打印 PASS/FAIL 汇总
rem ============================================================
setlocal
set ROOT=D:\code\Vivado\Loogarch_workspace_kimi
set SUB=%ROOT%\t26-perf-submit-trio
set CHIPLAB=D:\code\Vivado\Loogarch_workspace_kimi\chiplab
set VIVADO=C:\Xilinx\Vivado\2023.2\bin\vivado.bat

echo ==== [1/3] 同步最新网表到 chiplab/IP/myCPU ====
copy /y "%SUB%\src\mycpu\mycpu_top.v" "%CHIPLAB%\IP\myCPU\mycpu_top.v" >nul || goto :fail
if not exist "%CHIPLAB%\IP\myCPU\core_top.v" (echo [FAIL] core_top.v missing & goto :fail)
if not exist "%CHIPLAB%\IP\myCPU\xilinx_ip\multiplier\multiplier.xci" (echo [FAIL] multiplier.xci missing & goto :fail)
echo OK

echo ==== [2/3] 构建功能测试镜像 ====
if defined FUNC_BIN (
  copy /y "%FUNC_BIN%" "%CHIPLAB%\software\examples\nscscc_func\obj\main.bin" >nul || goto :fail
  echo Use external image: %FUNC_BIN%
) else (
  wsl.exe -d Ubuntu -- bash -lc "export PATH=$HOME/la32r/tc/loongarch32r-linux-gnusf-2022-05-20/bin:$PATH; cd /mnt/d/code/Vivado/Loogarch_workspace_kimi/chiplab/software/examples/nscscc_func && make 2>&1 | tail -3" || goto :fail
)

echo ==== [3/3] Vivado 建工程(首次) + xsim 仿真 ====
echo 注意: 全设计仿真可能需要 10-40 分钟, 日志为 func_sim.log
cd /d %CHIPLAB%\fpga\nscscc-team\run_vivado || goto :fail
call "%VIVADO%" -mode batch -source "%ROOT%\exam_prep\fpga\tcl\run_func_sim.tcl" -log func_sim.log -journal func_sim.jou

findstr /C:"----PASS!!!" func_sim.log >nul
if %errorlevel%==0 (
  echo.
  echo ========== 功能测试全部通过 PASS ==========
  echo 通过测试点明细见 func_sim.log 中 "Functional Test Point PASS" 行
  exit /b 0
)
findstr /C:"FAIL" func_sim.log >nul && (echo ========== 功能测试 FAIL, 查 func_sim.log ========== & goto :fail)
echo [WARN] 日志中未见 PASS/FAIL 结论, 请打开 func_sim.log 确认仿真是否跑完
goto :fail

:fail
echo.
echo ########## 流程失败, 见上方输出 ##########
exit /b 1
