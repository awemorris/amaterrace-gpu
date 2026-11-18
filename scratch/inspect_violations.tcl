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

# 1. Pattern A
show_path {b2d/state_reg[0]_rep__3/C} {b2d/r_dbase_reg[0]/CE} "Pattern A: state to r_dbase/CE"

# 2. Pattern B
show_path {b2d/m_rev_reg/C} {b2d/cur_bst_room_reg[0]/D} "Pattern B: m_rev to cur_bst_room/D"

# 3. Pattern C
show_path {b2d/cur_bst_room_reg[3]/C} {b2d/rows_b_reg[0]/CE} "Pattern C: cur_bst_room to rows_b/CE"

# 4. Pattern D
show_path {b2d/r_dst_delta_back_reg[1]/C} {b2d/rem_line_row_reg[1]/D} "Pattern D: r_dst_delta_back to rem_line_row/D"

# 5. Pattern E
show_path {b2d/bank_active_reg[1]/C} {b2d/bank_ready_reg[0]/D} "Pattern E: bank_active to bank_ready/D"

exit
