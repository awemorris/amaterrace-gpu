open_checkpoint build/asic_lint/atg_rop/post_synth.dcp
set c [get_cells wb/wpix/g_fblend.fblend/next[15]_i_1]
puts "PINS OF CELL:"
foreach p [get_pins -of_objects $c] {
    puts "  $p dir=[get_property DIRECTION $p] net=[get_nets -of_objects $p]"
}
puts "INIT: [get_property INIT $c]"
