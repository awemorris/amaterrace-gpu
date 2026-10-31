open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
create_clock -period 4.000 -name clk [get_ports clk]
puts [report_timing -from [get_pins b2d/cfg/s_op_reg[8]/C] -to [get_pins b2d/dst_row_b_reg[31]/D] -return_string]
exit 0
