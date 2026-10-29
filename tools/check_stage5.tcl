
open_checkpoint build/synth_module/atg_su/atg_su.dcp
report_timing -from [get_pins -hier *s5_sum_reg*/*C*] -to [get_pins -hier *s6_*_reg*/*D*] -max_paths 5
