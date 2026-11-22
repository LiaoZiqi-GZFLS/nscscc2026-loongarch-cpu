# Route from the already-placed checkpoint (place completed), lower memory:
# 4 jobs, no incremental.
open_checkpoint ./project/loongson.runs/impl_1/soc_top_placed.dcp
route_design -directive Explore
report_timing_summary -delay_type max -max_paths 10 -file ./project/loongson.runs/impl_1/timing_max.rpt
set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]]
puts "TIMING setup_WNS=$wns"
write_bitstream -force ./project/loongson.runs/impl_1/soc_top.bit
puts "BITSTREAM=project/loongson.runs/impl_1/soc_top.bit"
puts "BUILD_DONE"
