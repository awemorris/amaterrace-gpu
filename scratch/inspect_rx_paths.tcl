open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set p [get_timing_paths -to [get_pins setup/edge_u/ccw_reg/D]]
puts "Path cells to ccw_reg:"
foreach c [get_cells -of_objects $p] {
    puts "  $c ([get_property REF_NAME $c])"
}
set p2 [get_timing_paths -to [get_pins setup/edge_u/g_edge_regs[0].g_ee_s[2].eE_pk_reg[47]/D]]
puts "Path cells to eE_pk_reg[47]:"
foreach c [get_cells -of_objects $p2] {
    puts "  $c ([get_property REF_NAME $c])"
}
set p3 [get_timing_paths -to [get_pins setup/edge_u/g_48b_regs[2].dd_reg[47]/D]]
puts "Path cells to dd_reg[47]:"
foreach c [get_cells -of_objects $p3] {
    puts "  $c ([get_property REF_NAME $c])"
}
exit
