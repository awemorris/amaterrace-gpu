open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set c [get_cells b2d/p_dline[13]_i_1]
puts "Cell $c:"
puts [get_property INIT $c]
foreach p [get_pins -of_objects $c -filter {DIRECTION == IN}] {
    puts "  pin $p: [get_nets -of_objects $p] (driver: [get_pins -leaf -of_objects [get_nets -of_objects $p] -filter {DIRECTION == OUT}])"
}
