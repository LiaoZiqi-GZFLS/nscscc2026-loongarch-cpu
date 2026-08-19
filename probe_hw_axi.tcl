open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
refresh_hw_server [get_hw_servers]
set targets [get_hw_targets]
puts "TARGETS=$targets"
if {[llength $targets] == 0} { error "No hardware targets found" }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "DEVICE=$dev"
refresh_hw_device $dev
puts "AXI_OBJECTS=[get_hw_axis]"
foreach a [get_hw_axis] {
  puts "AXI=$a NAME=[get_property NAME $a]"
}
exit
