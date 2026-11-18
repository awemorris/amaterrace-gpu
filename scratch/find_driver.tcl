open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets {scan/g_coarse.u_coarse/cur_tx_reg[0]}]
puts "FLAT PIN COUNT: [get_property FLAT_PIN_COUNT $n]"
puts "SEGMENTS: [get_nets -segments $n]"
puts "ROOT NET: [get_nets -top_net_of_hierarchical_group $n]"
set pins [get_pins -of_objects $n]
foreach p $pins {
    if {[get_property DIRECTION $p] == "OUT"} {
        puts "DRIVER PIN: $p ([get_property REF_NAME [get_cells -of_objects $p]])"
    }
}
puts "SAMPLE LOAD PINS:"
puts [lrange [get_pins -of_objects $n -filter {DIRECTION == IN}] 0 10]
