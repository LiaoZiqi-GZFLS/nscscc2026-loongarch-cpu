open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }
foreach offset {000 100 200 300 400} {
  set name read_diag_${offset}_txn
  set address [format "1C220%s" $offset]
  create_hw_axi_txn $name $axi -address $address -len 64 -type read
  run_hw_axi $name
  puts "LINUX_TLB_DIAG_${offset}=[report_hw_axi_txn $name]"
  delete_hw_axi_txn $name
}
exit
