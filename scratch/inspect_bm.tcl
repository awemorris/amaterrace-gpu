open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set cell [get_cells -quiet setup/b_m_hi[0]_i_1]
if {$cell != ""} {
    puts "Cell: $cell"
    puts "Cell type: [get_property REF_NAME $cell]"
    puts "Pins:"
    foreach pin [get_pins -of_objects $cell] {
        puts "  $pin : [get_property DIRECTION $pin] net=[get_nets -of_objects $pin]"
    }
    puts "Cell equation: [get_property INIT $cell]"
}
exit
