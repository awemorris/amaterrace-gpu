open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -to [get_pins b2d/p_dline_reg[0]/CE] -max_paths 1]
puts [report_timing -of_objects $p -return_string]
