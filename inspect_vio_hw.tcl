open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set vio [lindex [get_hw_vios] 0]
puts "VIO=$vio"
puts "VIO_PROPERTIES=[list_property $vio]"
foreach prop {OUTPUT_VALUE INPUT_VALUE PROBE_OUT0 PROBE_OUT1 PROBE_OUT2 PROBE_IN4} {
  if {![catch {get_property $prop $vio} value]} { puts "VIO_$prop=$value" }
}
exit
