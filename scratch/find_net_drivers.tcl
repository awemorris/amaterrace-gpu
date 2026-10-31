set nets [get_nets -filter {NAME =~ "*sync_line_n_12*" || NAME =~ "*p_0_in_0*" || NAME =~ "*in00_1*"}]
foreach n $nets {
    set d [get_pins -of_objects $n -filter {DIRECTION == "OUT"}]
    puts "NET: $n DRIVER: $d"
}
exit
