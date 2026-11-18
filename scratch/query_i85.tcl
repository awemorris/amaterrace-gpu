open_checkpoint build/asic_lint/atg_su/post_synth.dcp
set net [get_nets -hierarchical *i___85_i_3_n_0*]
puts "NETS: $net"
if {[llength $net] > 0} {
    set n0 [lindex $net 0]
    puts "DRIVERS of $n0: [get_pins -leaf -of_objects $n0 -filter {DIRECTION == OUT}]"
    set pins [get_pins -leaf -of_objects $n0 -filter {DIRECTION == IN}]
    puts "LOADS count: [llength $pins]"
    puts "LOADS sample: [lrange $pins 0 5]"
}
