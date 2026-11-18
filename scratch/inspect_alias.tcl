open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set nets [get_nets -hierarchical -filter {NAME =~ "*qy_reg[15]_2*"}]
puts "FOUND NETS: $nets"
foreach n $nets {
    puts "NET: $n"
    puts "  FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
    puts "  TOP_NET: [get_property TOP_NET_OF_HIERARCHICAL_GROUP $n]"
    puts "  PARENT_CELL: [get_property PARENT_CELL $n]"
}
