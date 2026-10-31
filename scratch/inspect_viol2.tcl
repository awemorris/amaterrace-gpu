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

show_path {b2d/state_reg[4]_rep__5/C} {b2d/state_reg[2]/D} "state[4] -> state[2]"
show_path {b2d/state_reg[4]_rep__5/C} {b2d/state_reg[0]/D} "state[4] -> state[0]"
show_path {b2d/rem_b_reg[2]/C} {b2d/cur_bst_room_reg[1]/D} "rem_b -> cur_bst_room[1]"
show_path {b2d/m_stile_reg_rep__1/C} {b2d/cur_bst_room_reg[3]/D} "m_stile -> cur_bst_room[3]"
show_path {b2d/da_reg[3]/C} {b2d/r_leg_room_reg[5]/D} "da[3] -> r_leg_room[5]"
show_path {b2d/r_delta_px_back_reg[1]/C} {b2d/rem_line_row_reg[5]/D} "r_delta_px_back -> rem_line_row[5]"
show_path {b2d/cur_da_row_reg[4]/C} {b2d/rem_line_row_reg[4]/D} "cur_da_row -> rem_line_row[4]"

exit
