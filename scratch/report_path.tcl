open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
report_timing -from [get_cells b2d/rem_b_reg[2]] -to [get_pins b2d/rem_line_row_reg[0]/CE]
