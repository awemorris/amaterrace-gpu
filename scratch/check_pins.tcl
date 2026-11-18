open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set pins [get_pins -of [get_nets scan/coarse_busy]]
puts "COARSE_BUSY PINS: [llength $pins]"
foreach p $pins {
    puts "  PIN: $p"
}
exit
