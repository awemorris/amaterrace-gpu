open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set c [get_cells b2d/m_keep[3]_i_1]
puts "CELL: $c"
puts "REF_NAME: [get_property REF_NAME $c]"
puts "INIT: [get_property INIT $c]"
foreach p [get_pins -of_objects $c] {
    puts "PIN: $p ([get_property DIRECTION $p]) net: [get_nets -of_objects $p]"
}
set net [get_nets b2d/m_keep[3]_i_1_n_0]
puts "NET loads count: [get_property FLAT_PIN_COUNT $net]"
foreach ld [get_pins -leaf -of_objects $net -filter {DIRECTION == IN}] {
    puts "  LOAD: $ld"
}
