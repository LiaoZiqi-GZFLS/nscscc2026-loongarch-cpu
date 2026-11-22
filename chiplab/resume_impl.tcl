# Resume impl_1 from the existing (completed) synth_1, skip phys_opt.
open_project ./project/loongson.xpr
reset_run impl_1
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
proc wait_run {run timeout_min} {
  set deadline [expr {[clock seconds] + ($timeout_min * 60)}]
  while {1} {
    set st [get_property STATUS [get_runs $run]]
    set prog [get_property PROGRESS [get_runs $run]]
    puts "POLL $run status=$st progress=$prog"
    if {$st eq "write_bitstream Complete!"} { return 1 }
    if {$st eq "ERROR" || [string match "*ERROR*" $st]} { puts "RUN $run ERROR"; return 0 }
    if {[clock seconds] > $deadline} { puts "RUN $run TIMEOUT"; return 0 }
    after 15000
  }
}
if {![wait_run impl_1 120]} { error "impl_1 failed" }
open_run impl_1
set setup_wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]]
puts "TIMING setup_WNS=$setup_wns"
puts "BITSTREAM=project/loongson.runs/impl_1/soc_top.bit"
puts "BUILD_DONE"
