open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
report_timing -from [get_pins b2d/cur_da_row_reg[3]/C] -to [get_pins b2d/step_px_reg[0]/D]
exit 0
