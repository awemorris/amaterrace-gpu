open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set m [lindex [get_cells -hierarchical -filter {REF_NAME =~ "RAM*"}] 0]
set p [get_timing_paths -to [get_pins $m/ADDRA[0]] -max_paths 1]
puts "Path to $m/ADDRA[0]:"
puts "  Levels: [get_property LOGIC_LEVELS $p]"
puts "  Cells:  [get_cells -of_objects $p]"
