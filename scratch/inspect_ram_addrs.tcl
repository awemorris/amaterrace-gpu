open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
puts "--- Port A ADDR [5..14] sources ---"
for {set i 5} {$i <= 14} {incr i} {
    set pin [get_pins "$m/ADDRARDADDR\[$i\]"]
    set p [get_timing_paths -to $pin -max_paths 1]
    puts "ADDRARDADDR\[$i\]: [get_property STARTPOINT_PIN $p] (lev: [get_property LOGIC_LEVELS $p])"
}

puts "--- Port B ADDR [5..14] sources ---"
for {set i 5} {$i <= 14} {incr i} {
    set pin [get_pins "$m/ADDRBWRADDR\[$i\]"]
    set p [get_timing_paths -to $pin -max_paths 1]
    puts "ADDRBWRADDR\[$i\]: [get_property STARTPOINT_PIN $p] (lev: [get_property LOGIC_LEVELS $p])"
}
