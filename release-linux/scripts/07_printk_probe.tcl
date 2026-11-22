# 07_printk_probe.tcl — dump printk ring buffer (PA 0x1C747C2C) + bss start + UART TX test
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

puts "PRINTK_DUMP_BEGIN"  ;# ring buffer at PA 0x1C747C2C
for {set a 0x1C747C2C} {$a < 0x1C747E2C} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "PRINTK_DUMP_END"

puts "BSS_BEGIN"  ;# bss starts at 0x1C73698C
for {set a 0x1C73698C} {$a < 0x1C736A0C} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "BSS_END"

puts "UART_W0_BEFORE=[rd $axi 1FE001E0]"
# TX test: write THR='A' (0x41), keep IER=05 FCR=C1 LCR=13 -> word 13c10541
wr $axi 1FE001E0 13c10541
puts "WROTE_THR_A"
puts "UART_W0_AFTER =[rd $axi 1FE001E0]"
puts "UART_W4_AFTER =[rd $axi 1FE001E4]"
puts "PROBE_DONE"
exit
