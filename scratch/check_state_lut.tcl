open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
foreach p [get_pins -filter {DIRECTION == IN} -of [get_cells b2d/state[1]_i_2]] {
    puts "$p: [get_nets -of $p]"
}
