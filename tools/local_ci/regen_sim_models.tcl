# 重新生成 xsim 仿真需要的 IP 模型(流水线会删掉 gen 目录)
# 用法: vivado -mode batch -source regen_sim_models.tcl
set ipdir "D:/code/Vivado/Loongarch_workspace/chiplab/chip/soc_demo/nscscc-team/xilinx_ip"
foreach ip {clk_pll mig_axi_32 axi_crossbar_2x3 jtag_axi} {
    set xci [glob -nocomplain "$ipdir/$ip/$ip.xci"]
    if {[llength $xci] != 1} { puts "SKIP $ip (xci not found)"; continue }
    create_project -in_memory -part xc7a200tfbg676-2
    read_ip [lindex $xci 0]
    puts "generate_target simulation for $ip"
    catch { generate_target simulation [get_ips] }
    close_project
}
puts "REGEN_SIM_MODELS_DONE"
