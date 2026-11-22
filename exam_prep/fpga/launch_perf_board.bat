@echo off
rem arg1 = CPU MHz (105), arg2 = netlist source (pristine trio build)
call D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\perf_test_board.bat 105 D:\code\Vivado\Loogarch_workspace_kimi\t26-perf-submit-trio-pristine\src\vivado_cannot\build\mycpu_top.v > D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\perf_board.log 2>&1
