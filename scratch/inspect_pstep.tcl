open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets "setup/p_step__0[0]"]
puts "NET: $net, FANOUT: [get_property FLAT_PIN_COUNT $net]"
puts "DRIVER: [get_pins -leaf -of_objects $net -filter {DIRECTION == OUT}]"
set pins [get_pins -of_objects $net -filter {DIRECTION == IN}]
foreach p [lrange $pins 0 20] {
    puts "  LOAD: $p"
}
exit
