open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
set r1_errors 0
foreach p $top_paths {
    set cells [get_cells -of_objects $p]
    set lut_cnt 0
    set carry_cnt 0
    set dsp_cnt 0
    set pre_carry_lut 0
    set post_carry_lut 0
    set post_dsp_lut 0
    set seen_carry 0
    set seen_dsp 0
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[string match "LUT*" $ref]} {
            incr lut_cnt
            if {!$seen_carry} { incr pre_carry_lut } else { incr post_carry_lut }
            if {$seen_dsp} { incr post_dsp_lut }
        } elseif {[string match "CARRY*" $ref]} {
            incr carry_cnt
            set seen_carry 1
        } elseif {[string match "DSP*" $ref]} {
            incr dsp_cnt
            set seen_dsp 1
        }
    }
    if {$carry_cnt == 0 && $dsp_cnt == 0} {
        if {$lut_cnt > 4} {
            puts "Random Logic ($lut_cnt LUTs): [get_property STARTPOINT_PIN $p] --> [get_property ENDPOINT_PIN $p]"
        }
    }
    if {$carry_cnt > 0} {
        if {$pre_carry_lut > 1 || $post_carry_lut > 1} {
            puts "Adder/Sub (Pre: $pre_carry_lut, Post: $post_carry_lut, C4: $carry_cnt): [get_property STARTPOINT_PIN $p] --> [get_property ENDPOINT_PIN $p]"
        }
    }
}
