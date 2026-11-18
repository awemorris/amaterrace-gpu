open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins {b2d/state_reg[4]_rep__6/C}] -to [get_pins {b2d/state_reg[0]/D}]]
puts "Path cells for state:"
foreach c [get_cells -of_objects $p] {
    puts "  cell: $c ([get_property REF_NAME $c])"
}
exit
