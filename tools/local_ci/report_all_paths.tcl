# 200MHz 路径普查:列出所有 slack < 0.5ns 的 setup 路径(覆盖全部
# 超过 5ns 周期的路径),按 cpu_clk 域过滤
open_project project/loongson.xpr
open_run impl_1
report_timing -delay_type max -max_paths 200 -nworst 1 -slack_lesser_than 0.5 \
    -file all_paths_200.rpt
puts "REPORT_DONE"
