open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets -of [get_pins b2d/cur_b_dst_delta_lo[4]_i_1/O]]
puts "Loads of cur_b_dst_delta_lo[4]_i_1:"
foreach p [get_pins -of $n -filter {DIRECTION == IN}] {
    puts "  $p"
}
