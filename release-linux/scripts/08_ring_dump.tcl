# 08_ring_dump.tcl — dump 8KB more of printk ring + TX test byte
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

puts "RING2_BEGIN"
for {set a 0x1C747E2C} {$a < 0x1C748A2C} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "RING2_END"

# TX test: 'A' into THR while capture runs (keep regs as-is: IER=05 FCR=C1 LCR=13)
wr $axi 1FE001E0 13c10541
after 500
wr $axi 1FE001E0 13c10542
after 500
wr $axi 1FE001E0 13c10543
puts "TX_TEST_ABC_DONE"
puts "UART_W0=[rd $axi 1FE001E0]"
puts "PROBE_DONE"
exit
