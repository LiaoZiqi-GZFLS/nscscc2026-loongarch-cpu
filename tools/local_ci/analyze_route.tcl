# Round-3 post-route analysis: run AFTER bit.tcl routing completes.
# Usage: vivado -mode batch -source local_ci/analyze_route.tcl
set run_dir "D:/code/Vivado/Loongarch_workspace/chiplab/fpga/nscscc-team/run_vivado"
set out_dir "D:/code/Vivado/Loongarch_workspace/analysis_round3"
file mkdir $out_dir
open_checkpoint $run_dir/project/loongson.runs/impl_1/soc_top_routed.dcp
report_timing_summary -delay_type max -max_paths 10 -file $out_dir/timing_summary.rpt
report_timing -from [get_clocks cpu_clk] -to [get_clocks cpu_clk] -delay_type max -max_paths 60 -sort_by slack -file $out_dir/cpu_clk_top60.rpt
report_timing -delay_type max -max_paths 60 -sort_by slack -file $out_dir/all_top60.rpt
report_design_analysis -logic_level_distribution -of_timing_paths [get_timing_paths -delay_type max -max_paths 2000 -filter {SLACK < 0}] -file $out_dir/level_dist.rpt
report_qor_suggestions -file $out_dir/qor_suggestions.rpt
puts "ANALYSIS DONE -> $out_dir"
