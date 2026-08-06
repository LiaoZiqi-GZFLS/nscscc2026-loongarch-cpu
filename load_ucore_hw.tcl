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
  }
  close $input
  puts [format "WRITE_DONE file=%s address=0x%08X bytes=%d" $filename $start_addr $written]
}

set image "/mnt/d/project/T2026143250012561/sw/ucore/out/ucore.bin"
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }

write_reg $axi 80000000 00000000
write_bin $axi $image 0x1C000000
puts "VERIFY=[read_reg $axi 1C000000]"
write_reg $axi 40000000 00000000
puts "UCORE_CPU_RELEASED"
exit
