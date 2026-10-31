open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
report_timing -to [get_pins scan/g_slice_er_ec[0].er_reg[0][0]/D] -max_paths 1
exit
