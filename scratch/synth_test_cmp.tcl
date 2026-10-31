read_verilog scratch/test_cmp.v
synth_design -top test_cmp -part xc7k325tffg900-2 -mode out_of_context
report_timing -to [get_pins q_reg/D]
exit
