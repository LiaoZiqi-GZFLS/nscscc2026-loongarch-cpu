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
puts "LOGBUF_PTR=[rd $axi 1C6FAD34]"
puts "UART=[rd $axi 1FE001E4]"
set p [rd $axi 1C6FAD34]
# ring 起点 = 指针值 - 0xa0000000 (VA->PA)
set base [expr {0x$p - 0xa0000000}]
puts "RING_BASE=[format %08X $base]"
for {set a $base} {$a < [expr {$base + 0x800}]} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "PROBE_DONE
exit