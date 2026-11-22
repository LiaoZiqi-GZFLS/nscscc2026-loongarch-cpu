# 针对性提取:VPPN 簇与 MULDIV 簇的代表路径逐段明细
open_project project/loongson.xpr
open_run impl_1

puts "=== PATH 1: TLBTable_5_VPPN -> IF1 physAddr[13] ==="
report_timing -from [get_pins u_cpu/u_nop_core/toplevel_cpu/MMUPlugin_TLBTable_5_VPPN_reg[5]/C] \
    -to [get_pins u_cpu/u_nop_core/toplevel_cpu/IF1_to_IF2_TLB_TRANSLATE_RESULT_payload_physAddr_reg[13]/D] \
    -delay_type max -file vppn_path.rpt
puts "=== PATH 2: MULDIV signed -> issue queue valid ==="
report_timing -from [get_pins u_cpu/u_nop_core/toplevel_cpu/MULDIV_RRD_to_MULDIV_EXE_ISSUE_SLOT_uop_signed_reg_replica/C] \
    -to [get_pins u_cpu/u_nop_core/toplevel_cpu/IntIssueQueuePlugin_queue_0_payload_rRegs_1_valid_reg/D] \
    -delay_type max -file muldiv_path.rpt
puts "DONE"
