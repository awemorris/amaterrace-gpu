open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets -hierarchical "scan/g_coarse.u_coarse/qy_reg[15]_2"]
puts "NET: $n"
if {[llength $n] > 0} {
    set flat_pins [get_pins -leaf -of_objects $n]
    puts "FLAT PIN COUNT: [llength $flat_pins]"
    puts "FLAT PINS (first 20): [lrange $flat_pins 0 19]"
}
