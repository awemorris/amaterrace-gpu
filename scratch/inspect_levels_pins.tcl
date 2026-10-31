open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
set p [get_timing_paths -from [get_pins $m/DOBDO[0]] -max_paths 1]
puts "Levels: [get_property LOGIC_LEVELS $p]"
puts "Path cells: [get_cells -of_objects $p]"
puts "Path pins:  [get_pins -of_objects $p]"
