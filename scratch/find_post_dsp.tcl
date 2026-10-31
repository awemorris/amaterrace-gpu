open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
foreach p $top_paths {
    set cells [get_cells -of_objects $p]
    set dsp_cnt 0
    set post_dsp_lut 0
    set seen_dsp 0
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[string match "LUT*" $ref]} {
            if {$seen_dsp} { incr post_dsp_lut }
        } elseif {[string match "DSP*" $ref]} {
            incr dsp_cnt
            set seen_dsp 1
        }
    }
    if {$dsp_cnt > 0 && $post_dsp_lut > 1} {
        puts "Path: [get_property STARTPOINT_PIN $p] --> [get_property ENDPOINT_PIN $p] has post_dsp_lut = $post_dsp_lut"
        foreach c $cells {
            puts "   $c ([get_property REF_NAME $c])"
        }
    }
}
exit
