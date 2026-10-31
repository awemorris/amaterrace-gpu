open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set c1 [get_cells b2d/u_skid_p_i_126]
puts "c1: [get_property INIT $c1]"
foreach pin [get_pins -of_objects $c1] {
    puts "  pin $pin net: [get_nets -of_objects $pin]"
}
set c2 [get_cells b2d/u_skid_p_i_96]
puts "c2: [get_property INIT $c2]"
foreach pin [get_pins -of_objects $c2] {
    puts "  pin $pin net: [get_nets -of_objects $pin]"
}
exit
