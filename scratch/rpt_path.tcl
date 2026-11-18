open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
create_clock -period 4.0 [get_ports clk]
set p [get_timing_paths -from [get_cells -hierarchical *state_reg*] -to [get_cells -hierarchical *px_b_reg*] -max_paths 1]
puts "=== PATH 1 ==="
report_timing -of $p
set p2 [get_timing_paths -from [get_cells -hierarchical *da_reg*] -to [get_cells -hierarchical *sn_reg*] -max_paths 1]
puts "=== PATH 2 ==="
report_timing -of $p2
exit
