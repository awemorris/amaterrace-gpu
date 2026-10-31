open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
foreach name {"scan_n_0" "scan_n_1" "scan_n_2"} {
    set n [get_nets -hier "*$name*"]
    puts "NET: $n, fanout: [get_property FLAT_PIN_COUNT $n]"
    puts "  DRIVER: [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]"
    set pins [get_pins -of_objects $n]
    puts "  LOADS ([llength $pins]):"
    foreach p [lrange $pins 0 5] {
        puts "    $p"
    }
}
exit
