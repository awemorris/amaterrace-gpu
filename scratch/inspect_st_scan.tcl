open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets scan/st_reg_n_0_[1]]
puts "NET: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == "IN"}]
foreach p [lrange $pins 0 20] {
    puts "  PIN: $p"
}
exit
