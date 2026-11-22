# 09_reset_uart_test.tcl — hold CPU reset, let host pump UART bytes, then probe FIFO + TX
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
proc wr {axi address data} {
  create_hw_axi_txn t $axi -address $address -type write -data $data
  run_hw_axi t
  delete_hw_axi_txn t
}

puts "UART_PRE_RESET=[rd $axi 1FE001E0] [rd $axi 1FE001E4]"
puts "HOLDING_CPU_RESET"
wr $axi 80000000 00000000
after 25000
puts "RESET_HELD_25S"
puts "UART_AFTER_PUMP=[rd $axi 1FE001E0] [rd $axi 1FE001E4]"
# pop up to 8 RX bytes (offset 0 read = RBR)
for {set i 0} {$i < 8} {incr i} {
  set v [rd $axi 1FE001E0]
  puts "RBR_POP_$i=$v"
}
puts "UART_AFTER_POPS=[rd $axi 1FE001E4]"
# TX test with CPU stopped: write 'Z' to THR
wr $axi 1FE001E0 13c1055A
puts "WROTE_THR_Z"
after 2000
puts "UART_AFTER_TXZ=[rd $axi 1FE001E0] [rd $axi 1FE001E4]"
puts "RELEASING_CPU"
wr $axi 40000000 00000000
puts "PROBE_DONE"
exit
