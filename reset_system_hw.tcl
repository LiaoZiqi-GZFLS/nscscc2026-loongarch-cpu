open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
puts "VIOS=[get_hw_vios]"
puts "PROBES=[get_hw_probes]"
set vio [lindex [get_hw_vios] 0]
set reset_probe [lindex [get_hw_probes -quiet resetn_vio] 0]
set status_probe [lindex [get_hw_probes -quiet ddr_status_vio] 0]
if {$vio eq "" || $reset_probe eq "" || $status_probe eq ""} {
  error "Required VIO reset/status probes not found"
}
set_property OUTPUT_VALUE 0 $reset_probe
commit_hw_vio $reset_probe
after 100
set_property OUTPUT_VALUE 1 $reset_probe
commit_hw_vio $reset_probe
set elapsed 0
set ready 0
while {$elapsed <= 30000} {
  refresh_hw_vio $vio
  set raw [get_property INPUT_VALUE $status_probe]
  scan $raw %x status
  if {($status & 0x7) == 0x7} { set ready 1; break }
  after 100
  incr elapsed 100
}
puts "DDR_READY=$ready ELAPSED_MS=$elapsed STATUS=$status"
if {!$ready} { error "DDR did not become ready" }
exit
