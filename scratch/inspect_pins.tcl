
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
foreach n {setup_n_4 setup_n_5 scan_n_120} {
    set net [get_nets -quiet $n]
    puts "======================================"
    puts "NET: $n (fanout: [get_property -quiet FLAT_PIN_COUNT $net])"
    set pins [get_pins -leaf -of $net]
    puts "PIN COUNT: [llength $pins]"
    puts "PINS: [lrange $pins 0 9]"
}
exit 0

