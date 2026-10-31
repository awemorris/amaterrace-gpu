open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set c [get_cells -hier *q_valid_reg*]
puts "CELL: $c"
foreach cell $c {
    puts "CELL $cell type [get_property REF_NAME $cell] parent [get_property PARENT $cell]"
    set net [get_nets -of_objects [get_pins $cell/Q]]
    puts "NET: $net FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $net]"
}
