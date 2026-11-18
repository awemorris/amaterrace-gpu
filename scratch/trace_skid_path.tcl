open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins b2d/state_reg[4]*/C] -to [get_pins b2d/u_skid_p/g_slice[0].r_out_data_reg[0]/CE] -max_paths 1]
puts [report_timing -of_objects $p -return_string]
exit
