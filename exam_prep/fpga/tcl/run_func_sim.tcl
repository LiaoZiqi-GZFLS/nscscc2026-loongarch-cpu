# 功能测试 xsim 仿真驱动
# 用法（cwd = chiplab/fpga/nscscc-team/run_vivado）：
#   vivado -mode batch -source run_func_sim.tcl
# 判读：func_sim.log 出现 "----PASS!!!" 为全部通过；单项通过打印
#   "----[<time>] Number 8'dNN Functional Test Point PASS!!!"
# 注意：官方 run_func_test.tcl 的路径约定是"在工程目录里执行"
# （GUI Tcl Console 里 cd [get_property DIRECTORY [current_project]]），
# 本脚本显式 cd 到工程目录保持一致。

if {![file exists project/loongson.xpr]} {
  puts "Project not found, creating..."
  source create_project.tcl
}
open_project project/loongson.xpr

# 确保 multiplier IP 在工程中（现场带回的 chiplab 副本缺 xci 时补录并生成仿真模型）
if {[llength [get_ips -quiet multiplier]] == 0} {
  set mult_xci {D:/code/Vivado/Loogarch_workspace_kimi/chiplab/IP/myCPU/xilinx_ip/multiplier/multiplier.xci}
  if {![file exists $mult_xci]} {
    error "multiplier.xci not found: $mult_xci"
  }
  add_files -norecurse $mult_xci
  upgrade_ip -quiet [get_ips -quiet multiplier]
  generate_target all [get_ips multiplier]
  puts "multiplier IP added and generated."
}

cd [get_property DIRECTORY [current_project]]

# 与官方 run_func_test.tcl 一致：镜像放到 run_vivado/inst_data.bin
# （测试台在 xsim 目录读 ../../../../../inst_data.bin）
file copy -force ../../../../software/examples/nscscc_func/obj/main.bin ../inst_data.bin

# 跑到测试台 $finish 为止（默认 1000ns 太短）
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

launch_simulation
close_sim
exit
