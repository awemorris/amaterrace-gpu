open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
foreach p $top_paths {
    set ep [get_property ENDPOINT_PIN $p]
    if {[string match "*ccw_reg*" $ep]} {
        puts "FOUND $ep:"
        set dsp_cnt 0
        set post_dsp_lut 0
        set seen_dsp 0
        foreach c [get_cells -of_objects $p] {
            set ref [get_property REF_NAME $c]
            puts "  $c ($ref)"
            if {[string match "LUT*" $ref]} {
                if {$seen_dsp} { incr post_dsp_lut }
            } elseif {[string match "DSP*" $ref]} {
                set seen_dsp 1
            }
        }
        puts "post_dsp_lut = $post_dsp_lut"
    }
}
exit
