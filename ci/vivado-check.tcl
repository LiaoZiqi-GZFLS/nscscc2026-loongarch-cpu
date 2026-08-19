set repo_root [file normalize [lindex $argv 0]]
set work_dir [file normalize [lindex $argv 1]]
file mkdir $work_dir

create_project -force local_ci $work_dir -part xc7a200tfbg676-2
add_files [glob -nocomplain "$repo_root/src/mycpu/*.v"]

set xci_files [glob -nocomplain "$repo_root/src/mycpu/xilinx_ip/*/*.xci"]
if {[llength $xci_files] > 0} {
    foreach xci $xci_files {
        import_ip -files $xci -name [file rootname [file tail $xci]]
    }
    upgrade_ip [get_ips]
    generate_target all [get_ips]
    foreach ip [get_ips] {
        set synth_file "$work_dir/local_ci.gen/sources_1/ip/$ip/synth/$ip.vhd"
        if {[file exists $synth_file]} {
            read_vhdl $synth_file
        }
    }
}

set_property top core_top [current_fileset]
update_compile_order -fileset sources_1
synth_design -rtl -name rtl_1
report_drc -file "$work_dir/rtl_drc.rpt"
close_project
