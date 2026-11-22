open_project project/loongson.xpr
open_run impl_1
report_timing -from [get_pins u_cpu/u_nop_core/toplevel_axiBuffer/FSM_onehot_writeOutputFSM_stateReg_reg[3]/C] \
    -to [get_pins u_cpu/u_nop_core/toplevel_cpu/IntIssueQueuePlugin_queue_2_payload_rRegs_1_valid_reg/D] \
    -delay_type max -file wakeup_path.rpt
puts DONE
