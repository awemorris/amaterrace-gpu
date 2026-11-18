set net [get_nets -quiet {exp_n_164}]
if {$net ne ""} {
    puts "Driver of $net: [get_pins -of_objects $net -filter {DIRECTION == OUT}]"
    set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
    puts "Load count: [llength $loads]"
    foreach l [lrange $loads 0 5] {
        puts "  Load: $l"
    }
}
exit
