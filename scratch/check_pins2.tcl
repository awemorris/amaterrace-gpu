open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set pins [get_pins -of [get_nets setup/b_m_lo[0]]]
puts "B_M_LO PINS: [llength $pins]"
foreach p $pins {
    puts "  PIN: $p"
}
set pins2 [get_pins -of [get_nets setup/b_o_lo[0]]]
puts "B_O_LO PINS: [llength $pins2]"
foreach p $pins2 {
    puts "  PIN: $p"
}
exit
