open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets -hierarchical *qy_reg[15]_2*]
puts "NET: $n"
if {[llength $n] > 0} {
    puts "DRIVER: [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
    puts "NUM LOADS: [get_property FLAT_PIN_COUNT $n]"
    puts "SAMPLE LOADS: [lrange [get_pins -of_objects $n -filter {DIRECTION == IN}] 0 10]"
}
