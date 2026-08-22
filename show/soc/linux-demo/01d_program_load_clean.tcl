# 01_program_and_load.tcl
#   烧写 CPU 比特流 + 加载 Linux 镜像到 DDR，并保持 CPU 复位。
#   用法: vivado -mode batch -source 01_program_and_load.tcl
#   随后运行 02_release_cpu.tcl 释放 CPU 开始启动。
#
# 前置条件: hw_server 已在 localhost:3121 运行（Vivado 会自动拉起）。

set here      [file dirname [file normalize [info script]]]
set root      [file dirname $here]
set bitstream [file join $root bit   soc_top.bit]
set image_dir [file join $root linux]

proc write_reg {axi address data} {
  create_hw_axi_txn wr $axi -address $address -data $data -type write
  run_hw_axi wr
  delete_hw_axi_txn wr
}
proc read_reg {axi address} {
  create_hw_axi_txn rd $axi -address $address -type read
  run_hw_axi rd
  set v [lindex [report_hw_axi_txn rd] 1]
  delete_hw_axi_txn rd
  return $v
}

# 通过 JTAG-AXI 批量写入二进制文件（每次 1KB 突发）
proc write_bin {axi filename start_addr} {
  set input [open $filename rb]
  fconfigure $input -translation binary
  set addr $start_addr
  set written 0
  while {1} {
    set data [read $input 1024]
    set dlen [string length $data]
    if {$dlen == 0} { break }
    set plen [expr {($dlen + 3) & ~3}]
    if {$plen != $dlen} {
      append data [string repeat "\x00" [expr {$plen - $dlen}]]
    }
    binary scan $data cu* bytes
    set words {}
    for {set i 0} {$i < $plen} {incr i 4} {
      lappend words [format "%02X%02X%02X%02X" \
        [lindex $bytes [expr {$i+3}]] [lindex $bytes [expr {$i+2}]] \
        [lindex $bytes [expr {$i+1}]] [lindex $bytes $i]]
    }
    create_hw_axi_txn bw $axi -address [format "%08X" $addr] \
      -len [expr {$plen/4}] -type write -data [join [lreverse $words] _]
    run_hw_axi bw
    delete_hw_axi_txn bw
    incr addr $plen
    incr written $dlen
    if {$written % 2097152 < 1024} {
      puts "  ... $written / [file size $filename] bytes"
    }
  }
  close $input
  puts "WRITE_DONE [file tail $filename] @0x[format %08X $start_addr] $written bytes"
}

# 清零区间（用于 .bss —— objcopy 不会输出该段内容）
proc clear_range {axi s e} {
  set addr $s
  while {$addr < $e} {
    set bytes [expr {$e - $addr}]
    if {$bytes > 1024} { set bytes 1024 }
    set words [expr {($bytes + 3) / 4}]
    create_hw_axi_txn cl $axi -address [format "%08X" $addr] -len $words \
      -type write -data [join [lrepeat $words 00000000] _]
    run_hw_axi cl
    delete_hw_axi_txn cl
    incr addr [expr {$words * 4}]
  }
  puts "CLEAR_DONE 0x[format %08X $s]..0x[format %08X $e]"
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
set_msg_config -id {Labtoolstcl 44-481} -suppress
refresh_hw_server [get_hw_servers]
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
current_hw_device $dev

puts "=== 烧写比特流 $bitstream ==="
set_property PROGRAM.FILE $bitstream $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAM_DONE"

# 等 DDR3 MIG 校准完成
after 3000
refresh_hw_device $dev
set axi [lindex [get_hw_axis hw_axi_1] 0]
if {$axi eq ""} { error "hw_axi_1 not found —— 比特流是否包含 JTAG-AXI master?" }

puts "=== 保持 CPU 复位 ==="
write_reg $axi 80000000 00000000

puts "=== 加载镜像 ==="
write_bin $axi [file join $image_dir start.bin]   0x1C000000
write_bin $axi [file join $image_dir vmlinux.bin] 0x1C300000

# 清零内核 .bss（memsz - filesz）
set f [open [file join $image_dir load-sizes.txt] r]
set sizes [gets $f]
close $f
scan $sizes "%x %x" kfs kms
set kfe [expr {0x1C300000 + [file size [file join $image_dir vmlinux.bin]]}]
set kme [expr {0x1C300000 + $kms}]
clear_range $axi $kfe $kme

puts "VERIFY_START =[read_reg $axi 1C000000]  (期望 1438440f)"
puts "VERIFY_KERNEL=[read_reg $axi 1C300000]"
puts ""
puts "IMAGES_LOADED_RESET_HELD"
puts "下一步: vivado -mode batch -source 02_release_cpu.tcl"
exit
