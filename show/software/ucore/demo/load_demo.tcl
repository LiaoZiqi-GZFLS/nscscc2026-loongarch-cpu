# load_demo.tcl - JTAG-AXI image loader for the NSCSCC2026 finals demo
# (bootloader + ucore two-act showcase; driven by demo.py)
#
# Environment:
#   HW_SERVER_URL      hw_server address (default localhost:3121)
#   RESET_ONLY=1       assert CPU reset (write 0x80000000) and exit
#   IMAGE0..IMAGE2     image file paths (file normalize is applied)
#   ADDR0..ADDR2       load addresses, hex (default IMAGE0 -> 0x1C000000)
#   RELEASE=1|0        release CPU after loading (default 1)
#
# CPU reset protocol (chiplab nscscc-team SoC, JTAG-AXI hw_axi_1):
#   assert reset : write 0x80000000 = 0
#   release     : write 0x40000000 = 0
# Every image is written in 1 KiB bursts and verified at 3 offsets
# (first word / middle / last word); all progress prints go to stdout
# so the host script can relay the complete log.
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
  set next_report [expr {$start_addr + 65536}]
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
        [lindex $bytes [expr {$i + 3}]] \
        [lindex $bytes [expr {$i + 2}]] \
        [lindex $bytes [expr {$i + 1}]] \
        [lindex $bytes $i]]
    }
    create_hw_axi_txn burst_write_txn $axi \
      -address [format "%08X" $addr] \
      -len [expr {$padded_len / 4}] -type write -data [join [lreverse $words] _]
    run_hw_axi burst_write_txn
    delete_hw_axi_txn burst_write_txn
    incr addr $padded_len
    incr written $data_len
    if {$addr >= $next_report} {
      puts [format "WRITE_PROGRESS file=%s address=0x%08X bytes=%d" \
        $filename $addr $written]
      set next_report [expr {$addr + 65536}]
    }
  }
  close $input
  puts [format "WRITE_DONE file=%s address=0x%08X bytes=%d" $filename $start_addr $written]
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

proc load_image {axi filename base tag} {
  set image [file normalize $filename]
  if {![file exists $image]} { error "image not found: $image" }
  set written [write_bin $axi $image $base]
  set offsets [list 0 [expr {($written / 2) & ~3}] [expr {($written - 4) & ~3}]]
  foreach offset $offsets {
    set expected [file_word $image $offset]
    set actual [read_reg $axi [format "%08X" [expr {$base + $offset}]]]
    puts [format "VERIFY tag=%s address=0x%08X expected=%s actual=%s" \
      $tag [expr {$base + $offset}] $expected $actual]
    if {![string equal -nocase $expected $actual]} {
      error [format "image verification failed (tag=%s) at 0x%08X" $tag \
        [expr {$base + $offset}]]
    }
  }
}

set server [env_or HW_SERVER_URL localhost:3121]

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

if {[env_or RESET_ONLY 0] == 1} {
  write_reg $axi 80000000 00000000
  puts "DEMO_RESET_HELD"
  exit
}

write_reg $axi 80000000 00000000
after 500

set default_addr 0x1C000000
for {set i 0} {$i < 3} {incr i} {
  set image [env_or IMAGE$i ""]
  set addr [env_or ADDR$i [format "0x%08X" $default_addr]]
  set default_addr [expr {$default_addr + 0x400000}]
  if {$image ne ""} {
    load_image $axi $image [expr $addr] "image$i"
  }
}

puts "DEMO_LOAD_DONE"
if {[env_or RELEASE 1] == 1} {
  write_reg $axi 40000000 00000000
  puts "DEMO_CPU_RELEASED"
}
exit
