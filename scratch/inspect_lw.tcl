open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set c [get_cells "setup/line_width[0]_i_40"]
puts "CELL: $c"
foreach p [get_pins -of_objects $c] {
    puts "  $p -> [get_nets -of_objects $p]"
}
set net [get_nets "setup/line_width[0]_i_40_n_0"]
set loads [get_pins -of_objects $net -filter {DIRECTION == IN}]
puts "LOAD COUNT: [llength $loads]"
foreach l [lrange $loads 0 10] {
    puts "  LOAD: $l"
}
exit
