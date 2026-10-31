open_checkpoint build/atg_blt/synth/atg_blt.dcp
report_timing -from [get_cells b2d/bank_closed_reg*] -to [get_cells b2d/cur_b_dst_step_reg*] -max_paths 1
report_timing -from [get_cells b2d/cur_b_dst_step_reg*] -to [get_cells b2d/step_px_reg*] -max_paths 1
report_timing -from [get_cells b2d/psl_reg*] -to [get_cells b2d/r_init_step_px_reg*] -max_paths 1
