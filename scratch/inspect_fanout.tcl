open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
puts "=== state[1]_i_2 net ==="
set n [get_nets -of [get_pins b2d/state[1]_i_2/O]]
puts "Net: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
puts "Loads:"
foreach p [get_pins -of $n -filter {DIRECTION == IN}] {
    puts "  $p"
}
puts "=== cur_b_dst_delta_lo[4]_i_1 net ==="
set n [get_nets -of [get_pins b2d/cur_b_dst_delta_lo[4]_i_1/O]]
puts "Net: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
