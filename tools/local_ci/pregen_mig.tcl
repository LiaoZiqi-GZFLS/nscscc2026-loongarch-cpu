# 本地适配:launch_runs 的批量 IP 生成路径在 Windows 本机会卡在 mig_axi_32
# 的 updateAllModelParams(batch 上下文失败,直接 generate_target 成功),
# 因此在 bit.tcl 之前单独预生成 mig 输出产物。不改变设计与时序门禁语义。
open_project project/loongson.xpr
generate_target all [get_ips mig_axi_32]
close_project
puts "PREGEN_MIG_DONE"
