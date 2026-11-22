# 06_logbuf_probe.tcl — dump kernel printk log_buf + UART regs, then clear LCR break bit
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
proc wr {axi address data {size 4}} {
  create_hw_axi_txn t $axi -address $address -size $size -type write -data $data
  run_hw_axi t
  delete_hw_axi_txn t
}

# UART regs BEFORE
puts "PRE_UART_WORD0 =[rd $axi 1FE001E0]"
puts "PRE_UART_WORD4 =[rd $axi 1FE001E4]"

# log_buf PA = 0x1c6fad34 (VA bc6fad34 - 0xa0000000). Dump 256 bytes as words.
puts "LOGBUF_DUMP_BEGIN"
for {set a 0x1C6FAD00} {$a < 0x1C6FAE00} {incr a 0x10} {
  set line [format "%08X" $a]
  for {set o 0} {$o < 16} {incr o 4} {
    append line " [rd $axi [format %08X [expr {$a + $o}]]]"
  }
  puts $line
}
puts "LOGBUF_DUMP_END"

# also: bss first words (was zeroed at load)
puts "BSS_AT_1C736948 =[rd $axi 1C736948] [rd $axi 1C73694C] [rd $axi 1C736950] [rd $axi 1C736954]"

# clear break: LCR = 0x03 (8N1)
wr $axi 1FE001E3 03 1
puts "LCR_SET_03"
puts "POST_UART_WORD0=[rd $axi 1FE001E0]"
puts "PROBE_DONE"
exit
