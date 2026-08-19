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

    set burst_data [join [lreverse $words] _]
    create_hw_axi_txn burst_write_txn $axi \
      -address [format "%08X" $addr] \
      -len [expr {$padded_len / 4}] \
      -type write \
      -data $burst_data
    run_hw_axi burst_write_txn
    delete_hw_axi_txn burst_write_txn

    incr addr $padded_len
    incr written $data_len
    if {$written % 1048576 < $chunk_size} {
      puts [format "WRITE_PROGRESS file=%s bytes=%d" $filename $written]
    }
  }

  close $input
  puts [format "WRITE_DONE file=%s address=0x%08X bytes=%d" $filename $start_addr $written]
}

proc clear_range {axi start_addr end_addr} {
  set addr $start_addr
  while {$addr < $end_addr} {
    set bytes [expr {$end_addr - $addr}]
    if {$bytes > 1024} { set bytes 1024 }
    set words [expr {($bytes + 3) / 4}]
    create_hw_axi_txn clear_txn $axi \
      -address [format "%08X" $addr] -len $words -type write \
      -data [join [lrepeat $words 00000000] _]
    run_hw_axi clear_txn
    delete_hw_axi_txn clear_txn
    incr addr [expr {$words * 4}]
  }
  puts [format "CLEAR_DONE start=0x%08X end=0x%08X" $start_addr $end_addr]
}

set image_dir "/mnt/d/project/T2026143250012561/sw/linux/out/board-16m"
if {[info exists ::env(LINUX_IMAGE_DIR)]} { set image_dir $::env(LINUX_IMAGE_DIR) }
set start_bin [file join $image_dir start.bin]
set kernel_bin [file join $image_dir vmlinux.bin]
set initrd_bin [file join $image_dir rootfs.cpio.gz]
set load_sizes [file join $image_dir load-sizes.txt]
if {![file exists $load_sizes]} { error "Missing kernel load metadata: $load_sizes" }
set sizes_file [open $load_sizes r]
set sizes [gets $sizes_file]
close $sizes_file
if {[scan $sizes "%x %x" kernel_file_size kernel_mem_size] != 2} {
  error "Invalid kernel load metadata: $sizes"
}

open_hw_manager
set hw_url "localhost:3121"
if {[info exists ::env(HW_SERVER_URL)]} { set hw_url $::env(HW_SERVER_URL) }
connect_hw_server -url $hw_url -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
set targets [get_hw_targets]
if {[llength $targets] == 0} { error "No hardware targets found" }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} { error "xc7a200t device not found" }
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found" }

puts "CPU_RESET=assert"
write_reg $axi 80000000 00000000
clear_range $axi 0x1C220000 0x1C220500
write_bin $axi $start_bin 0x1C000000
write_bin $axi $kernel_bin 0x1C300000
if {[file exists $initrd_bin]} {
  write_bin $axi $initrd_bin 0x1CA00000
}
# vmlinux.bin omits NOBITS .bss. Clear the full tail of the ELF LOAD segment
# so repeated board boots never inherit stale kernel global state.
set kernel_file_end [expr {0x1C300000 + [file size $kernel_bin]}]
set kernel_mem_end [expr {0x1C300000 + $kernel_mem_size}]
clear_range $axi $kernel_file_end $kernel_mem_end

if {![info exists ::env(SKIP_LOAD_VERIFY)] || !$::env(SKIP_LOAD_VERIFY)} {
  puts "VERIFY_START=[read_reg $axi 1C000000]"
  puts "VERIFY_KERNEL=[read_reg $axi 1C300000]"
}
puts "CPU_RESET=held"
exit
