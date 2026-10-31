open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets "scan/g_coarse.u_coarse/qy_reg[15]_2"]
puts "NET NAME: [get_property NAME $n]"
puts "FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
puts "PARENT_CELL: [get_property PARENT_CELL $n]"
set pins [get_pins -of_objects $n]
foreach p $pins {
    puts "PIN: $p  DIR: [get_property DIRECTION $p]  IS_LEAF: [get_property IS_LEAF $p]"
}
