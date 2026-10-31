open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins {b2d/g_mr_reg[32].r_mr_buf_reg[32]/C}] -to [get_pins b2d/rem_line_row_reg[2]/D] -max_paths 1]
puts [report_timing -of_objects $p -return_string]
exit
