open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
report_timing -from [get_pins b2d/cur_bst_room_reg[2]/C] -to [get_pins b2d/rem_line_row_reg[0]/CE]
report_timing -from [get_pins b2d/cur_bst_room_reg[2]/C] -to [get_pins b2d/cur_bst_room_reg[1]/D]
report_timing -from [get_pins b2d/m_rev_reg/C] -to [get_pins b2d/r_d_xb_reg[15]/D]
