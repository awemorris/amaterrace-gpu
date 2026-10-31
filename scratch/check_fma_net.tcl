open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets "setup/fm_a_lo[15]_i_26_n_0"]
puts "NET: $n"
if {[llength $n] > 0} {
    puts "FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
    set driver [get_pins -filter {DIRECTION == OUT} -leaf -of_objects $n]
    puts "DRIVER: $driver"
    set loads [get_pins -filter {DIRECTION == IN} -leaf -of_objects $n]
    puts "LOAD COUNT: [llength $loads]"
    puts "SAMPLE LOADS: [lrange $loads 0 10]"
}
