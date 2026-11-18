
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets -quiet p_0_in]
set loads [get_pins -leaf -of $net -filter {DIRECTION == IN}]
puts "Total loads: [llength $loads]"
foreach pin [lrange $loads 0 20] {
    puts "  PIN: $pin"
}
