open_checkpoint build/asic_lint/atg_su/post_synth.dcp
set net [get_nets exp/g_bank[6].b_sc_on_c1]
puts "Driver of $net: [get_pins -of_objects $net -filter {DIRECTION == OUT}]"
set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
puts "Load count: [llength $loads]"
foreach l $loads {
    puts "  Load: $l"
}
exit
