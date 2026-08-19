open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
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

if {$dev eq ""} {
  error "No hardware devices found"
}

puts "PROGRAM_DEVICE=$dev"
set bitstream /tmp/opencode/chiplab-nscscc2026/fpga/nscscc-team/run_vivado/project/loongson.runs/impl_1/soc_top.bit
if {[info exists ::env(BITSTREAM)]} { set bitstream $::env(BITSTREAM) }
set_property PROGRAM.FILE $bitstream $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAM_DONE=[get_property PROGRAM.FILE $dev]"
exit
