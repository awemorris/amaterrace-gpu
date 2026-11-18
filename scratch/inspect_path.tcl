open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_timing_paths -from [get_pins b2d/cur_bst_room_reg[3]/C] -to [get_pins b2d/rows_b_reg[0]/CE]]
puts "Path cells:"
foreach c [get_cells -of_objects $p] {
    puts "  cell: $c ([get_property REF_NAME $c])"
}
exit
