# 时序违例诊断:提取 perf 构建 impl_1 的全部 setup 违例端点
# 用法:vivado -mode batch -source eval_violations.tcl(在 run_vivado 目录下执行)
open_project project/loongson.xpr
open_run impl_1

# 先落盘:全部违例路径的完整逐段明细(nworst 20 > 违例数 10,保证覆盖)
report_timing -delay_type max -max_paths 20 -nworst 20 -sort_by slack \
    -file all_violations_detail.rpt

set paths [get_timing_paths -delay_type max -slack_less_than 0.0 -max_paths 1000]
puts "TOTAL_SETUP_VIOLATIONS=[llength $paths]"
puts "=== per-path summary ==="
foreach p $paths {
    puts [format "slack=%+.3fns" [get_property SLACK $p]]
    puts "  start: [get_property STARTPOINT_PIN $p]"
    puts "  end:   [get_property ENDPOINT_PIN $p]"
}
puts "Wrote all_violations_detail.rpt"
