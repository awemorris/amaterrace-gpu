open_checkpoint build/asic_lint/atg_blt/atg_blt.dcp
report_timing -to [get_pins b2d/meta_be_0_reg*/*] -max_paths 1
report_timing -to [get_pins b2d/step_px_reg*/*] -max_paths 1
