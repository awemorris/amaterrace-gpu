open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
set p [get_timing_paths -from [get_pins $m/DOBDO[0]] -max_paths 1]
puts "Startpoint: [get_property STARTPOINT_PIN $p]"
puts "Endpoint:   [get_property ENDPOINT_PIN $p]"
puts "Levels:     [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  pin: $pin"
}
