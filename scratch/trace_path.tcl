open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
puts [report_timing -from [get_pins setup/fadd/g_lat4.r_ovalid_reg/C] -to [get_pins setup/seq_step_reg[0]/D] -return_string]
EOF
