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
  set chunk_size 1024
  while {1} {
    set data [read $input $chunk_size]
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

set image [file normalize [env_or UCORE_IMAGE "out/ucore.bin"]]
set base [expr {[env_or UCORE_LOAD_ADDR 0x1C000000]}]
set server [env_or HW_SERVER_URL localhost:3121]
if {![file exists $image]} { error "uCore image not found: $image" }

open_hw_manager
connect_hw_server -url $server -allow_non_jtag
refresh_hw_server [get_hw_servers]
set targets [get_hw_targets]
if {[llength $targets] == 0} { error "No hardware targets found" }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} { error "xc7a200t device not found" }
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found; program the system-test bitstream first" }

write_reg $axi 80000000 00000000
after 500
set written [write_bin $axi $image $base]
set offsets [list 0 [expr {($written / 2) & ~3}] [expr {($written - 4) & ~3}]]
foreach offset $offsets {
  set expected [file_word $image $offset]
  set actual [read_reg $axi [format "%08X" [expr {$base + $offset}]]]
  puts [format "VERIFY address=0x%08X expected=%s actual=%s" \
    [expr {$base + $offset}] $expected $actual]
  if {![string equal -nocase $expected $actual]} {
    error [format "Image verification failed at 0x%08X" [expr {$base + $offset}]]
  }
}
write_reg $axi 40000000 00000000
puts [format "UCORE_CPU_RELEASED bytes=%d address=0x%08X" $written $base]
exit
