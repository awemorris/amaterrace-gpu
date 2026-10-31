open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins b2d/px_b_reg[2]/C] -to [get_pins b2d/g_da_full_reg[31]/D] -max_paths 1]
puts [report_timing -of_objects $p -return_string]
