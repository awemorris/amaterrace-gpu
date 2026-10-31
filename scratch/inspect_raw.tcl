open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets "setup/raw"]
set pins [get_pins -of_objects $net -filter {DIRECTION == IN}]
foreach p $pins {
    puts "  LOAD: $p"
}
exit
