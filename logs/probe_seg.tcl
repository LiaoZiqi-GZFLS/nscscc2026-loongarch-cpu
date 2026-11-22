proc read_reg {axi address} {
  create_hw_axi_txn read_reg_txn $axi -address $address -type read
  run_hw_axi read_reg_txn
  set value [lindex [report_hw_axi_txn read_reg_txn] 1]
  delete_hw_axi_txn read_reg_txn
  return $value
}
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
puts [format "SEG=0x%08X" [read_reg $axi 1FAFF050]]
puts [format "DDR0=0x%08X" [read_reg $axi 1C000000]]
puts [format "TIMER=0x%08X" [read_reg $axi 1FAFE000]]
exit
