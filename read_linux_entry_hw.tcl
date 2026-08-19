open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }
foreach address {1C000000 1C220070 1C220074 1C220078 1C22007C 1C300000 3C300000 1C593DE0 3C593DE0 1FE001E0 3FE001E0 1C685120 1C693008 1C693024 1C730500} {
  set name read_${address}_txn
  create_hw_axi_txn $name $axi -address $address -len 4 -type read
  run_hw_axi $name
  puts "MEM_${address}=[report_hw_axi_txn $name]"
  delete_hw_axi_txn $name
}
exit
