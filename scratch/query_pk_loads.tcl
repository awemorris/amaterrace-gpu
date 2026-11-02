set net [get_nets -quiet {pk/g_lane[7].u_lo/i___84_i_3_n_0}]
if {$net ne ""} {
    puts "Driver of $net: [get_pins -of_objects $net -filter {DIRECTION == OUT}]"
    set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
    puts "Load count: [llength $loads]"
    foreach l [lrange $loads 0 10] {
        puts "  Load: $l"
    }
}
exit
