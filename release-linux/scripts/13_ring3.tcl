open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
proc rd {axi a} {
  create_hw_axi_txn t $axi -address $a -type read
  run_hw_axi t
  set v [lindex [report_hw_axi_txn t] 1]
  delete_hw_axi_txn t
  return $v
}
for {set a 0x1C747F0C} {$a < 0x1C74840C} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "PROBE_DONE
exit