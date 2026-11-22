open_project project/loongson.xpr
open_run impl_1
report_high_fanout_nets -timing -load_types -max_nets 25 -file hfn.txt
report_qor_suggestions -file qor.txt
puts DONE
