open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

proc show_path {from to desc} {
    puts "================================================================"
    puts "PATH: $desc"
    puts "================================================================"
    set p [get_timing_paths -from [get_pins $from] -to [get_pins $to] -max_paths 1]
    if {[llength $p] > 0} {
        puts [report_timing -of_objects $p -return_string]
    } else {
        puts "No path found from $from to $to"
    }
}

show_path {b2d/port/req_valid_reg/C} {b2d/port/req_be_reg[0]/CE} "Path 1: req_valid -> req_be[0] CE"
show_path {b2d/port/req_valid_reg/C} {b2d/state_reg[1]/D} "Path 2: req_valid -> state[1] D"

exit
