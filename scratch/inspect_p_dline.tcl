open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set net [get_nets b2d/p_dline[0]]
puts "Net: $net"
puts "Pin count: [llength [get_pins -of_objects $net]]"
foreach p [get_pins -of_objects $net] {
    puts "  PIN: $p"
}
