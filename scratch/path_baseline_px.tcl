open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins b2d/cur_da_b_reg[3]/C] -to [get_pins b2d/px_b_reg[10]/D] -max_paths 1]
report_timing -of_objects $p
exit 0
