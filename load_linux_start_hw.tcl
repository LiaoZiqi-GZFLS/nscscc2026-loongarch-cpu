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
  set data [read $input]
  close $input
  set data_len [string length $data]
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
  create_hw_axi_txn start_write_txn $axi \
    -address [format "%08X" $start_addr] \
    -len [expr {$padded_len / 4}] -type write \
    -data [join [lreverse $words] _]
  run_hw_axi start_write_txn
  delete_hw_axi_txn start_write_txn
  puts [format "WRITE_DONE address=0x%08X bytes=%d" $start_addr $data_len]
}

proc clear_range {axi start_addr end_addr} {
  set addr $start_addr
  while {$addr < $end_addr} {
    set bytes [expr {$end_addr - $addr}]
    if {$bytes > 1024} { set bytes 1024 }
    set words [expr {($bytes + 3) / 4}]
    create_hw_axi_txn clear_txn $axi -address [format "%08X" $addr] \
      -len $words -type write -data [join [lrepeat $words 00000000] _]
    run_hw_axi clear_txn
    delete_hw_axi_txn clear_txn
    incr addr [expr {$words * 4}]
  }
  puts [format "CLEAR_DONE start=0x%08X end=0x%08X" $start_addr $end_addr]
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }
write_reg $axi 80000000 00000000
write_bin $axi "/mnt/d/project/T2026143250012561/sw/linux/out/board-16m/start.bin" 0x1C000000
set kernel_bin "/mnt/d/project/T2026143250012561/sw/linux/out/board-16m/vmlinux.bin"
set load_sizes "/mnt/d/project/T2026143250012561/sw/linux/out/board-16m/load-sizes.txt"
if {![file exists $load_sizes]} { error "Missing kernel load metadata: $load_sizes" }
set sizes_file [open $load_sizes r]
set sizes [gets $sizes_file]
close $sizes_file
if {[scan $sizes "%x %x" kernel_file_size kernel_mem_size] != 2} {
  error "Invalid kernel load metadata: $sizes"
}
write_bin $axi $kernel_bin 0x1C300000
set kernel_file_end [expr {0x1C300000 + [file size $kernel_bin]}]
set kernel_mem_end [expr {0x1C300000 + $kernel_mem_size}]
clear_range $axi $kernel_file_end $kernel_mem_end
puts "VERIFY_START=[read_reg $axi 1C000000]"
puts "VERIFY_KERNEL=[read_reg $axi 1C300000]"
puts "CPU_RESET=held"
exit
