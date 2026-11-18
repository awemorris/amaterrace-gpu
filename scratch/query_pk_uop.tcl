set net [get_nets -quiet {x_uop_pk[80]}]
if {$net ne ""} {
    puts "Driver of $net: [get_pins -of_objects $net -filter {DIRECTION == OUT}]"
    set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
    puts "Load count: [llength $loads]"
    foreach l [lrange $loads 0 10] {
        puts "  Load: $l"
    }
}
exit
