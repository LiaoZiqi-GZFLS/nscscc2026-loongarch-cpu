# build_linux_bit.tcl — Linux bring-up bitstream build (batch-mode, polling)
# Replaces wait_on_run (GUI-only) with a polling loop.
# Usage: vivado -mode batch -source build_linux_bit.tcl -tclargs <build_kind>
set build_kind "sys"
if {$argc >= 1} { set build_kind [lindex $argv 0] }

proc wait_run {run timeout_min} {
  set deadline [expr {[clock seconds] + ($timeout_min * 60)}]
  while {1} {
    set st [get_property STATUS [get_runs $run]]
    set prog [get_property PROGRESS [get_runs $run]]
    puts "POLL $run status=$st progress=$prog"
    if {$st eq "synth_design Complete!" || $st eq "route_design Complete!" || $st eq "write_bitstream Complete!"} { return 1 }
    if {$st eq "ERROR" || [string match "*ERROR*" $st]} { puts "RUN $run ERROR"; return 0 }
    if {[clock seconds] > $deadline} { puts "RUN $run TIMEOUT"; return 0 }
    after 15000
  }
}

source create_project.tcl

# IP 升级会重新生成 *_sim_netlist.v，必须删除，否则 -scan_for_includes 会把它当综合源
foreach f [glob -nocomplain ../../../chip/soc_demo/nscscc-team/xilinx_ip/*/*_sim_netlist.v] { file delete -force $f }
foreach f [glob -nocomplain ../../../IP/myCPU/xilinx_ip/*/*_sim_netlist.v] { file delete -force $f }
puts "sim-netlist cleanup done"

puts "=== launching synth_1 ==="
reset_run synth_1
launch_runs synth_1 -jobs 8
if {![wait_run synth_1 60]} { error "synth_1 failed" }

puts "=== launching impl_1 (place/route/bitstream) ==="
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
if {![wait_run impl_1 120]} { error "impl_1 failed" }

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -file project/loongson.runs/impl_1/timing_summary.rpt
report_utilization -file project/loongson.runs/impl_1/utilization.rpt

set setup_wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]]
set hold_wns  [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -nworst 1] 0]]
puts "TIMING setup_WNS=$setup_wns hold_WNS=$hold_wns"
if {$setup_wns < 0.0} { puts "WARNING: setup WNS negative" }

puts "BITSTREAM=project/loongson.runs/impl_1/soc_top.bit"
puts "BUILD_DONE"
