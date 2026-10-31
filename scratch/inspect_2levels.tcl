open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set p [get_timing_paths -to [get_pins u_state/mem_b_reg/ADDRARDADDR[14]] -max_paths 1]
puts "Startpoint: [get_property STARTPOINT_PIN $p]"
puts "Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  Pin: $pin"
}
set pb [get_timing_paths -to [get_pins u_state/mem_b_reg/ADDRBWRADDR[14]] -max_paths 1]
puts "Port B Startpoint: [get_property STARTPOINT_PIN $pb]"
puts "Port B Levels: [get_property LOGIC_LEVELS $pb]"
foreach pin [get_pins -of_objects $pb] {
    puts "  Pin: $pin"
}
