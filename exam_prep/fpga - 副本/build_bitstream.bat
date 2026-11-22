@echo off
rem ============================================================
rem  t26-perf-submit-trio 比特流一键生成脚本
rem  用法:
rem    build_bitstream.bat          生成功能测试比特流(默认 func, clk_pll 默认配置)
rem    build_bitstream.bat func     同上
rem    build_bitstream.bat perf     生成性能测试比特流(按 src\perf_clock.json 的
rem                                 cpu_clk_mhz 重配 PLL, 当前为 105 MHz)
rem  产物:
rem    func -> t26-perf-submit-trio\bit\func_test\func_soc_top.bit
rem    perf -> t26-perf-submit-trio\bit\perf_test\perf_soc_top.bit
rem    同时保留在 run_vivado\project\loongson.runs\impl_1\ 供 vio.tcl 上板使用
rem  耗时: 约 45 分钟(综合+实现)
rem  注意: 请在正常 cmd 窗口运行(不要在 git bash 里调 vivado.bat)
rem ============================================================
setlocal enabledelayedexpansion
set ROOT=D:\code\Vivado\Loogarch_workspace_kimi
set SUB=%ROOT%\t26-perf-submit-trio
set CHIPLAB=D:\code\Vivado\Loogarch_workspace_kimi\chiplab
set VIVADO=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
set RUNDV=%CHIPLAB%\fpga\nscscc-team\run_vivado

set KIND=%~1
if "%KIND%"=="" set KIND=func
if /i not "%KIND%"=="func" if /i not "%KIND%"=="perf" (
  echo [FAIL] 未知参数 "%KIND%", 用法: build_bitstream.bat [func^|perf]
  exit /b 1
)

echo ==== [1/4] 同步最新网表到 chiplab/IP/myCPU ====
copy /y "%SUB%\src\mycpu\mycpu_top.v" "%CHIPLAB%\IP\myCPU\mycpu_top.v" >nul || goto :fail
if not exist "%CHIPLAB%\IP\myCPU\core_top.v" (echo [FAIL] core_top.v missing & goto :fail)
if not exist "%CHIPLAB%\IP\myCPU\xilinx_ip\multiplier\multiplier.xci" (echo [FAIL] multiplier.xci missing & goto :fail)
echo OK

cd /d %RUNDV% || goto :fail

rem ---- perf 模式: 按 perf_clock.json 重配 PLL ----
set CPU_MHZ=
if /i "%KIND%"=="perf" (
  echo ==== [2/4] 按 perf_clock.json 重配 PLL ====
  for /f "tokens=2 delims=:," %%a in ('findstr /C:"cpu_clk_mhz" "%SUB%\src\perf_clock.json"') do set CPU_MHZ=%%a
  set CPU_MHZ=!CPU_MHZ: =!
  echo cpu_clk_mhz = !CPU_MHZ!
  if "!CPU_MHZ!"=="" (echo [FAIL] 无法解析 perf_clock.json & goto :fail)
  call "%VIVADO%" -mode batch -source generate_perf_pll.tcl -tclargs !CPU_MHZ! -log gen_pll.log -journal gen_pll.jou
)

rem ---- 建工程(首次) ----
echo ==== [3/4] 建工程(首次) + 综合实现生成比特流, 约45分钟 ====
if not exist project\loongson.xpr (
  call "%VIVADO%" -mode batch -source create_project.tcl -log create_project.log -journal create_project.jou
)
if /i "%KIND%"=="perf" (
  call "%VIVADO%" -mode batch -source bit.tcl --tclargs perf !CPU_MHZ! -log bit.log -journal bit.jou
) else (
  call "%VIVADO%" -mode batch -source bit.tcl --tclargs func -log bit.log -journal bit.jou
)
if not exist project\loongson.runs\impl_1\soc_top.bit (
  echo [FAIL] 比特流未生成, 查 bit.log
  goto :fail
)

echo ==== [4/4] 时序核查与产物归位 ====
set VALID=project\loongson.runs\impl_1\clock_timing_validation.txt
if exist %VALID% type %VALID%
findstr /C:"setup_wns_ns=-" %VALID% >nul 2>nul && (
  echo [FAIL] setup WNS 为负, 性能成绩无效
  goto :fail
)
findstr /C:"hold_wns_ns=-" %VALID% >nul 2>nul && (
  echo [FAIL] hold WNS 为负, 性能成绩无效
  goto :fail
)

if /i "%KIND%"=="perf" (
  copy /y project\loongson.runs\impl_1\soc_top.bit "%SUB%\bit\perf_test\perf_soc_top.bit" >nul || goto :fail
  copy /y project\loongson.runs\impl_1\soc_top.ltx "%SUB%\bit\perf_test\perf_soc_top.ltx" >nul 2>nul
  echo [OK] 产物: %SUB%\bit\perf_test\perf_soc_top.bit
) else (
  copy /y project\loongson.runs\impl_1\soc_top.bit "%SUB%\bit\func_test\func_soc_top.bit" >nul || goto :fail
  copy /y project\loongson.runs\impl_1\soc_top.ltx "%SUB%\bit\func_test\func_soc_top.ltx" >nul 2>nul
  echo [OK] 产物: %SUB%\bit\func_test\func_soc_top.bit
)
echo.
echo ========== 比特流生成成功 (%KIND%) ==========
exit /b 0

:fail
echo.
echo ########## 流程失败, 见上方输出与 run_vivado 下的日志 ##########
exit /b 1
