open_project project/loongson.xpr
open_run impl_1
set paths [get_timing_paths -delay_type max -max_paths 20 -nworst 1]
puts "TOP20_PATHS"
foreach p $paths {
    puts [format "slack=%+.3fns start=%s end=%s" \
        [get_property SLACK $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
