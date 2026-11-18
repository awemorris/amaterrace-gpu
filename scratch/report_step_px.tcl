open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
report_timing -from [get_cells b2d/cur_da_row_reg*] -to [get_cells b2d/step_px_reg*] -max_paths 1
