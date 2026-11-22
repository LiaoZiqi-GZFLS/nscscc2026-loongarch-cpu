# 05_uart_probe.tcl — read UART + DDR status via JTAG AXI to diagnose boot state
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

proc rd {axi address} {
  create_hw_axi_txn t $axi -address $address -type read
  run_hw_axi t
  set v [lindex [report_hw_axi_txn t] 1]
  delete_hw_axi_txn t
  return $v
}

puts "UART_IER  =[rd $axi 1FE001E1]"
puts "UART_IIR  =[rd $axi 1FE001E2]"
puts "UART_LCR  =[rd $axi 1FE001E3]"
puts "UART_MCR  =[rd $axi 1FE001E4]"
puts "UART_LSR  =[rd $axi 1FE001E5]"
puts "DDR_START =[rd $axi 1C000000]  (expect 1438440f)"
puts "DDR_KERNEL=[rd $axi 1C300000]"
puts "DDR_START+4=[rd $axi 1C000004]"
puts "DDR_KERNEL+4=[rd $axi 1C300004]"
puts "PROBE_DONE"
exit
