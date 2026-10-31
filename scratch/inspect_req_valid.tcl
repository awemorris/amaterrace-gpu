open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set c [get_cells b2d/req_valid_INST_0_i_1]
puts "Cell: $c"
puts "Type: [get_property REF_NAME $c]"
puts "INIT: [get_property INIT $c]"
puts "Pins:"
foreach p [get_pins -of_objects $c] {
    set net [get_nets -of_objects $p]
    puts "  $p (net: $net, fo: [get_property FLAT_PIN_COUNT $net])"
}
