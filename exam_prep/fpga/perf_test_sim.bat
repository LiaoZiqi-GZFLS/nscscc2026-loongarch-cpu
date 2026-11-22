@echo off
rem ============================================================
rem  Performance test one-key script (xsim simulation route)
rem  20 benchmarks from software/examples/nscscc_perf/obj/*
rem  Log: chiplab/fpga/nscscc-team/run_vivado/perf_sim.log
rem  Note: full 20-benchmark run takes hours; safe to run overnight.
rem ============================================================
setlocal
set ROOT=D:\code\Vivado\Loogarch_workspace_kimi
set CHIPLAB=%ROOT%\chiplab
set VIVADO=C:\Xilinx\Vivado\2023.2\bin\vivado.bat

echo ==== [1/2] Sync latest netlist to chiplab/IP/myCPU ====
copy /y "%ROOT%\t26-perf-submit-trio\src\mycpu\mycpu_top.v" "%CHIPLAB%\IP\myCPU\mycpu_top.v" >nul || goto :fail
echo OK

echo ==== [2/2] Vivado batch (project build) + xsim perf run ====
cd /d %CHIPLAB%\fpga\nscscc-team\run_vivado || goto :fail
"%VIVADO%" -mode batch -source "%ROOT%\exam_prep\fpga\tcl\run_perf_sim.tcl" > perf_sim.log 2>&1
if errorlevel 1 goto :fail
echo [OK] perf simulation finished, see perf_sim.log
exit /b 0

:fail
echo [FAIL] perf_test_sim failed
exit /b 1
