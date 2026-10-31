open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
report_timing -from [get_pins b2d/rem_reg[2]/C] -to [get_pins b2d/r_leg_back_reg[4]/D]
exit 0
