open_checkpoint build/asic_lint/atg_su/post_synth.dcp
set net [get_nets exp/drain/d_q[2]_i_1_n_0]
puts "Driver of $net: [get_pins -of_objects $net -filter {DIRECTION == OUT}]"
set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
puts "Load count: [llength $loads]"
foreach l [lrange $loads 0 20] {
    puts "  Load: $l"
}
exit
