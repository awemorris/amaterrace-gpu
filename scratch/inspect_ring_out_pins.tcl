open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set n [get_nets u_ring/out]
puts "pins of u_ring/out:"
foreach p [get_pins -of_objects $n] {
    puts "  pin: $p ([get_property DIRECTION $p])"
}
