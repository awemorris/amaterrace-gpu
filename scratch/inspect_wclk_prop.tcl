
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets b2d/pp_ram_reg_r1_0_31_0_5/WCLK]
report_property $n
