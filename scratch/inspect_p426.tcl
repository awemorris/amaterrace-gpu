open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set n [get_nets -quiet "b2d/p_426_in"]
if {$n != ""} {
    puts "Driver: [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
    set loads [get_pins -of_objects $n -filter {DIRECTION == IN}]
    puts "Load count: [llength $loads]"
    puts "Loads (first 10): [lrange $loads 0 9]"
}

exit 0
