open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
puts "mem_b_reg CONFIG:"
puts "RAM_MODE: [get_property -quiet RAM_MODE $m]"
puts "READ_WIDTH_A: [get_property -quiet READ_WIDTH_A $m]"
puts "WRITE_WIDTH_A: [get_property -quiet WRITE_WIDTH_A $m]"
puts "READ_WIDTH_B: [get_property -quiet READ_WIDTH_B $m]"
puts "WRITE_WIDTH_B: [get_property -quiet WRITE_WIDTH_B $m]"
