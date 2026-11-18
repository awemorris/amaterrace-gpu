open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
puts "--- Port A EN & WE ---"
puts "ENARDEN: [get_nets -of_objects [get_pins $m/ENARDEN]]"
puts "WEA:     [get_nets -of_objects [get_pins $m/WEA[*]]]"
puts "--- Port B EN & WE ---"
puts "ENBWREN: [get_nets -of_objects [get_pins $m/ENBWREN]]"
puts "WEBWE:   [get_nets -of_objects [get_pins $m/WEBWE[*]]]"

puts "--- Port A ADDR ---"
foreach p [get_pins $m/ADDRARDADDR[*]] {
    set n [get_nets -of_objects $p]
    puts "$p --> $n"
}
