
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets b2d/pp_ram_reg_r2_0_31_96_101/DID1]
report_property $n
