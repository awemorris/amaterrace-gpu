open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
set pins [get_pins -of_objects $m]
foreach p $pins {
    set dir [get_property DIRECTION $p]
    if {$dir == "IN"} {
        set path [get_timing_paths -to $p -max_paths 1]
        if {$path != ""} {
            set lev [get_property LOGIC_LEVELS $path]
            if {$lev > 0} {
                puts "VIOL IN: $p | Lev: $lev | From: [get_property STARTPOINT_PIN $path]"
            }
        }
    } else {
        set path [get_timing_paths -from $p -max_paths 1]
        if {$path != ""} {
            set lev [get_property LOGIC_LEVELS $path]
            if {$lev > 0} {
                puts "VIOL OUT: $p | Lev: $lev | To: [get_property ENDPOINT_PIN $path]"
            }
        }
    }
}
