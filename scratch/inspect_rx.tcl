open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets scan/g_coarse.u_coarse/cur_tx_reg[0]]
if {$n != ""} {
    puts "Net: $n"
    set drv [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]
    puts "Driver: $drv ([get_property REF_NAME [get_cells -of_objects $drv]])"
    set loads [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
    puts "Load count: [llength $loads]"
    puts "First 10 loads: [lrange $loads 0 9]"
} else {
    puts "Net scan/g_coarse.u_coarse/cur_tx_reg[0] not found!"
}
exit
