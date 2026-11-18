open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set c1 [get_cells u_ring/n[15]_i_1]
foreach p [get_pins -of_objects $c1] {
    puts "pin: $p (net: [get_nets -of_objects $p])"
}
