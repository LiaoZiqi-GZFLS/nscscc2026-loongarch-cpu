# 导出仿真所需 Xilinx IP 的行为级仿真模型(iverilog 用)
# 用法:vivado -mode batch -source export_ip_sim_models.tcl
set out_dir [file normalize [file dirname [info script]]/../sim_ip_models]
file delete -force $out_dir
file mkdir $out_dir

create_project -in_memory -part xc7a200tfbg676-2

set ips [list \
    D:/code/Vivado/Loongarch_workspace/chiplab/chip/soc_demo/nscscc-team/xilinx_ip/jtag_axi/jtag_axi.xci \
    D:/code/Vivado/Loongarch_workspace/chiplab/chip/soc_demo/nscscc-team/xilinx_ip/axi_crossbar_2x3/axi_crossbar_2x3.xci \
    D:/code/Vivado/Loongarch_workspace/chiplab/chip/soc_demo/nscscc-team/xilinx_ip/vio/vio_0.xci \
    D:/code/Vivado/Loongarch_workspace/chiplab/IP/myCPU/xilinx_ip/multiplier/multiplier.xci \
]
set ip_objs {}
foreach xci $ips {
    if {[file exists $xci]} {
        lappend ip_objs [read_ip $xci]
    } else {
        puts "MISSING: $xci"
    }
}
generate_target simulation $ip_objs
export_simulation -of_objects $ip_objs -directory $out_dir -simulator vcs
puts "EXPORTED to $out_dir"
