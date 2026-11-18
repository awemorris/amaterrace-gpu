open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets scan/we_sp_idle]
puts "NET: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == "IN"}]
foreach p [lrange $pins 0 30] {
    puts "  PIN: $p"
}
exit
