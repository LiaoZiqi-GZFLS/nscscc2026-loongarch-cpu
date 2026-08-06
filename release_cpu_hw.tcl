open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }
create_hw_axi_txn release_cpu_txn $axi -address 40000000 -data 00000000 -type write
run_hw_axi release_cpu_txn
delete_hw_axi_txn release_cpu_txn
puts "CPU_RESET=released"
exit
