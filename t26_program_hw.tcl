open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server [get_hw_servers]
puts "SERVERS=[get_hw_servers]"
set targets [get_hw_targets]
puts "TARGETS=$targets"
foreach t $targets { puts "TARGET=$t" }
if {[llength $targets] == 0} {
  error "No hardware targets found"
}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices]
puts "DEVICES=$devices"
foreach d $devices { puts "DEVICE=$d PART=[get_property PART $d]" }
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} {
  set dev [lindex $devices 0]
}
puts "PROGRAM_DEVICE=$dev"
set_property PROGRAM.FILE /home/cjy/T2026143250012561/bit/sys_test/bit/sys_soc_top_100mhz.bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAM_DONE=[get_property PROGRAM.FILE $dev]"
exit
