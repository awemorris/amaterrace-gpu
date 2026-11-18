open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins b2d/state_reg[4]*/C] -to [get_pins b2d/r_leg_room_reg[2]/D] -max_paths 1]
puts [report_timing -of_objects $p -return_string]
exit
