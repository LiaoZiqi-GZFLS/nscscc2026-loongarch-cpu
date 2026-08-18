proc env_or {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} {
    return $::env($name)
  }
  return $default
}

proc write_reg {axi address data} {
  create_hw_axi_txn write_reg_txn $axi -address $address -data $data -type write
  run_hw_axi write_reg_txn
  delete_hw_axi_txn write_reg_txn
}

proc read_reg {axi address} {
  create_hw_axi_txn read_reg_txn $axi -address $address -type read
  run_hw_axi read_reg_txn
  set value [lindex [report_hw_axi_txn read_reg_txn] 1]
  delete_hw_axi_txn read_reg_txn
  return $value
}

proc write_bin {axi filename start_addr} {
  set input [open $filename rb]
  fconfigure $input -translation binary
  set addr $start_addr
  set written 0
  while {1} {
    set data [read $input 1024]
    set data_len [string length $data]
    if {$data_len == 0} { break }
    set padded_len [expr {($data_len + 3) & ~3}]
    if {$padded_len != $data_len} {
      append data [string repeat "\x00" [expr {$padded_len - $data_len}]]
    }
    binary scan $data cu* bytes
    set words {}
    for {set i 0} {$i < $padded_len} {incr i 4} {
      lappend words [format "%02X%02X%02X%02X" \
        [lindex $bytes [expr {$i + 3}]] [lindex $bytes [expr {$i + 2}]] \
        [lindex $bytes [expr {$i + 1}]] [lindex $bytes $i]]
    }
    create_hw_axi_txn burst_write_txn $axi -address [format "%08X" $addr] \
      -len [expr {$padded_len / 4}] -type write -data [join [lreverse $words] _]
    run_hw_axi burst_write_txn
    delete_hw_axi_txn burst_write_txn
    incr addr $padded_len
    incr written $data_len
  }
  close $input
  return $written
}

proc file_word {filename offset} {
  set input [open $filename rb]
  fconfigure $input -translation binary
  seek $input $offset start
  set data [read $input 4]
  close $input
  while {[string length $data] < 4} { append data "\x00" }
  binary scan $data cu4 bytes
  return [format "%02X%02X%02X%02X" \
    [lindex $bytes 3] [lindex $bytes 2] [lindex $bytes 1] [lindex $bytes 0]]
}

set bit_file [file normalize [env_or FUNC_BIT "bit/func_test/func_soc_top.bit"]]
set image [file normalize [env_or FUNC_BIN "/home/cjy/chiplab/software/examples/nscscc_func/obj/main.bin"]]
set probes_file [env_or FUNC_LTX ""]
if {$probes_file ne ""} { set probes_file [file normalize $probes_file] }
set server [env_or HW_SERVER_URL localhost:3121]
set timeout_ms [expr {[env_or FUNC_TIMEOUT 120] * 1000}]
set interval_ms [env_or POLL_INTERVAL_MS 200]
set expected [string toupper [env_or EXPECTED_NUM 3A00003A]]
set func_switch [string toupper [env_or FUNC_SWITCH FF]]
set base 0x1C000000
set num_addr 1FAFF050
set led_addr 1FAFF020
set led_rg0_addr 1FAFF030
set led_rg1_addr 1FAFF040

if {![file exists $bit_file]} { error "Function-test bitstream not found: $bit_file" }
if {![file exists $image]} { error "Function-test image not found: $image" }
if {$probes_file ne "" && ![file exists $probes_file]} {
  error "Function-test probes file not found: $probes_file"
}

open_hw_manager
connect_hw_server -url $server -allow_non_jtag
refresh_hw_server [get_hw_servers]
set targets [get_hw_targets]
if {[llength $targets] == 0} { error "No hardware targets found" }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} { error "xc7a200t device not found" }
set_property PROGRAM.FILE $bit_file $dev
if {$probes_file ne ""} {
  set_property PROBES.FILE $probes_file $dev
  set_property FULL_PROBES.FILE $probes_file $dev
}
program_hw_devices $dev
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found in function-test bitstream" }

write_reg $axi 80000000 00000000
after 500
set written [write_bin $axi $image $base]
foreach offset [list 0 [expr {($written / 2) & ~3}] [expr {($written - 4) & ~3}]] {
  set want [file_word $image $offset]
  set got [read_reg $axi [format "%08X" [expr {$base + $offset}]]]
  puts [format "IMAGE_VERIFY address=0x%08X expected=%s actual=%s" \
    [expr {$base + $offset}] $want $got]
  if {![string equal -nocase $want $got]} {
    error [format "Image verification failed at 0x%08X" [expr {$base + $offset}]]
  }
}

puts [format "FUNC_IMAGE_LOADED bytes=%d address=0x%08X" $written $base]
if {$probes_file ne ""} {
  set reset_probe [lindex [get_hw_probes -quiet resetn_vio] 0]
  set switch_probe [lindex [get_hw_probes -quiet switch_vio] 0]
  if {$reset_probe eq "" || $switch_probe eq ""} {
    error "resetn_vio/switch_vio probes not found in $probes_file"
  }
  set_property OUTPUT_VALUE $func_switch $switch_probe
  commit_hw_vio $switch_probe
  set_property OUTPUT_VALUE 0 $reset_probe
  commit_hw_vio $reset_probe
  after 1000
  set_property OUTPUT_VALUE 1 $reset_probe
  commit_hw_vio $reset_probe
  puts "FUNC_CPU_RELEASED method=vio_reset switch_vio=0x$func_switch"
  after 1000
} else {
  write_reg $axi 40000000 00000000
  puts "FUNC_CPU_RELEASED method=jtag"
}

set elapsed 0
set last ""
set changed 0
set pass 0
while {$elapsed <= $timeout_ms} {
  set value [string toupper [read_reg $axi $num_addr]]
  if {$value ne $last} {
    scan $value %x number
    set high [expr {($number >> 24) & 0xff}]
    set low [expr {$number & 0xff}]
    set sync [expr {$high == $low}]
    puts [format "NUM_DATA elapsed_ms=%d value=0x%s high=0x%02X low=0x%02X sync=%d" \
      $elapsed $value $high $low $sync]
    if {$last ne ""} { set changed 1 }
    set last $value
  }
  if {$value eq $expected} {
    set pass 1
    break
  }
  after $interval_ms
  incr elapsed $interval_ms
}

set led_rg0 00000000
set led_rg1 00000000
if {$pass} {
  for {set status_wait 0} {$status_wait < 2000} {incr status_wait 100} {
    set led_rg0 [read_reg $axi $led_rg0_addr]
    set led_rg1 [read_reg $axi $led_rg1_addr]
    if {[string equal -nocase $led_rg0 00000001] && \
        [string equal -nocase $led_rg1 00000001]} { break }
    after 100
  }
}
set led [read_reg $axi $led_addr]
puts "BOARD_STATUS num_data=0x$last led=0x$led led_rg0=0x$led_rg0 led_rg1=0x$led_rg1"
if {!$pass} { error "Function test timed out: expected 0x$expected, got 0x$last" }
if {![string equal -nocase $led_rg0 00000001] || ![string equal -nocase $led_rg1 00000001]} {
  error "Function test reached 0x$expected but status LEDs are not both green"
}
puts "CHIPLAB_FUNC_PASS expected=0x$expected elapsed_ms=$elapsed transitions_observed=$changed"
exit
