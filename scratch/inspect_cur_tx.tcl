open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set nets [get_nets -hier "*cur_tx_reg[0]*"]
foreach n $nets {
    puts "NET: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
    puts "  DRIVER: [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]"
}
exit
