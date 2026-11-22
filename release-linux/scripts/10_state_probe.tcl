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
puts "UART_W0=[rd $axi 1FE001E0]"
puts "UART_W4=[rd $axi 1FE001E4]"
puts "RING0=[rd $axi 1C747C2C] [rd $axi 1C747C30] [rd $axi 1C747C34] [rd $axi 1C747C38]"
puts "RING1=[rd $axi 1C747C3C] [rd $axi 1C747C40] [rd $axi 1C747C44] [rd $axi 1C747C48]"
puts "BSS0=[rd $axi 1C73698C] [rd $axi 1C736990]"
puts "PROBE_DONE
exit