open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set c [get_cells "setup/pl_lo[0][15]_i_2"]
puts "CELL: $c"
set net [get_nets "setup/pl_lo[0][15]_i_2_n_0"]
set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
puts "LOAD COUNT: [llength $loads]"
foreach l $loads {
    puts "  LOAD: $l"
}
exit
