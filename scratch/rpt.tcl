open_checkpoint build/asic_lint/atg_blt/atg_blt.dcp
report_timing -from [get_cells b2d/cur_da_b_reg[0]] -to [get_cells b2d/r_bst_seg_n_reg[0]]
report_timing -from [get_cells b2d/da_reg[3]] -to [get_cells b2d/sn_reg[0]]
