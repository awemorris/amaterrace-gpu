open_checkpoint build/asic_lint/atg_rop/post_synth.dcp
create_clock -period 5.000 clk
puts [report_timing -from [get_cells wb/FSM_sequential_st_reg*] -to [get_cells {wb/edat_reg[0][92]}] -return_string]
exit
