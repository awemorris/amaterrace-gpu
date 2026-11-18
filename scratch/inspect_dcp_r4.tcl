open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
set p [get_timing_paths -to [get_pins $m/ADDRARDADDR[5]] -max_paths 1]
puts "DCP ADDRARDADDR[5] startpoint: [get_property STARTPOINT_PIN $p]"
puts "DCP ADDRARDADDR[5] levels:     [get_property LOGIC_LEVELS $p]"
