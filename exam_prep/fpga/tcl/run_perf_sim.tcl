# Performance test xsim driver (20 benchmarks, restart + run all each)
# Usage (cwd = chiplab/fpga/nscscc-team/run_vivado):
#   vivado -mode batch -source run_perf_sim.tcl
# Log: perf_sim.log; each benchmark prints its counter summary before $finish.

if {![file exists project/loongson.xpr]} {
  puts "Project not found, creating..."
  source create_project.tcl
}
open_project project/loongson.xpr

# Ensure multiplier IP exists (field chiplab copy may lack the xci)
if {[llength [get_ips -quiet multiplier]] == 0} {
  set mult_xci {D:/code/Vivado/Loogarch_workspace_kimi/chiplab/IP/myCPU/xilinx_ip/multiplier/multiplier.xci}
  if {![file exists $mult_xci]} {
    error "multiplier.xci not found: $mult_xci"
  }
  add_files -norecurse $mult_xci
  upgrade_ip -quiet [get_ips -quiet multiplier]
  generate_target all [get_ips multiplier]
  puts "multiplier IP added and generated."
}

cd [get_property DIRECTORY [current_project]]

# First launch only compiles + elaborates (1000ns then return).
# The 20 benchmarks are driven by the official run_allbench.tcl
# (per benchmark: copy inst_data.bin -> restart -> run all).
set_property -name {xsim.simulate.runtime} -value {1000ns} -objects [get_filesets sim_1]

launch_simulation
source ../run_allbench.tcl
close_sim
exit
