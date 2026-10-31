open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set p [get_timing_paths -to [get_pins u_state/mem_b_reg/ADDRBWRADDR[5]] -max_paths 1]
puts "Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  pin: $pin"
}
