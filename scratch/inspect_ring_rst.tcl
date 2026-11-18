open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set c1 [get_cells u_ring/n[15]_i_1]
puts "n[15]_i_1 cell: $c1"
puts "  Ref: [get_property REF_NAME $c1]"
puts "  INIT: [get_property INIT $c1]"
foreach p [get_pins -of_objects $c1] {
    puts "  Pin: $p --> net [get_nets -of_objects $p]"
}

set c2 [get_cells u_ring/irq_q_i_1]
puts "irq_q_i_1 cell: $c2"
puts "  Ref: [get_property REF_NAME $c2]"
puts "  INIT: [get_property INIT $c2]"
foreach p [get_pins -of_objects $c2] {
    puts "  Pin: $p --> net [get_nets -of_objects $p]"
}
