# xsim 批量仿真:open 工程 → 行为仿真 → 跑指定时长
# 用法:vivado -mode batch -source sim_xsim.tcl -tclargs <run时间>
# TB 的 inst_data.bin 约定位于 run_vivado/(5 级 ../ 解析)。
open_project project/loongson.xpr
launch_simulation -mode behavioral -simset sim_1
set run_time [lindex $argv 0]
if {$run_time eq ""} { set run_time 100us }
puts "XSIM_RUN $run_time"
catch { run $run_time }
puts "XSIM_DONE"
exit
