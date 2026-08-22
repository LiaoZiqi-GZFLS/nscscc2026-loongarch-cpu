# 02_release_cpu.tcl
#   释放 CPU 复位，Linux 开始启动。
#   用法: vivado -mode batch -source 02_release_cpu.tcl
#   在此之前请先运行 01_program_and_load.tcl，并打开串口终端（COM3, 115200 8N1）。

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }

# 写 0x40000000 释放复位（0x80000000 为置位）
create_hw_axi_txn go $axi -address 40000000 -data 00000000 -type write
run_hw_axi go
delete_hw_axi_txn go
puts "CPU_RELEASED —— 请查看串口输出"
exit
