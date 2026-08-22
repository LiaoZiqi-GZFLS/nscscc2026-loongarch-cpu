# 00_probe_state.tcl — 探测板上状态,输出 STATE= 标记供 demo_launcher.py 解析
# 输出: STATE=NO_AXI (比特流不在板/无 JTAG-AXI) / EMPTY (DDR 无镜像) / READY (镜像在位)
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} {
  puts "STATE=NO_AXI"
  exit
}
proc rd {axi a} {
  create_hw_axi_txn t $axi -address $a -type read
  run_hw_axi t
  set v [lindex [report_hw_axi_txn t] 1]
  delete_hw_axi_txn t
  return $v
}
set s [rd $axi 1C000000]
set k [rd $axi 1C300000]
if {$s eq "1438440f" && $k eq "1c0060e7"} {
  puts "STATE=READY"
} else {
  puts "STATE=EMPTY start=$s kernel=$k"
}
exit
