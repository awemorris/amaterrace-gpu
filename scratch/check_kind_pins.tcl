
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets -quiet setup/kind[1]_i_1_n_0]
set loads [get_pins -leaf -of $net -filter {DIRECTION == IN}]
puts "Total loads: [llength $loads]"
foreach pin [lrange $loads 0 20] {
    puts "  PIN: $pin"
}
