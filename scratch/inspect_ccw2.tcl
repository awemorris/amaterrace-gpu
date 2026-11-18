open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
foreach p $top_paths {
    set ep [get_property ENDPOINT_PIN $p]
    if {[string match "*ccw_reg*" $ep]} {
        puts "Found ccw path: [get_property STARTPOINT_PIN $p] --> $ep"
        foreach c [get_cells -of_objects $p] {
            puts "  $c ([get_property REF_NAME $c])"
        }
    }
}
exit
