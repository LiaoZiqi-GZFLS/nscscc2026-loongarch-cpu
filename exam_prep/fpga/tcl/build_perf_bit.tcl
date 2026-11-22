# Bitstream build wrapper (cwd must be run_vivado; argv: func | perf <mhz>):
#   1. recreate the project from scratch via the official create_project.tcl
#      (idempotent: deletes ./project and stale IP gen dirs; picks up the
#       clk_pll XCI freshly reconfigured by generate_perf_pll.tcl)
#   2. source the official bit.tcl which runs impl_1 to write_bitstream
#      and validates clocks + WNS
source create_project.tcl
source bit.tcl
exit
